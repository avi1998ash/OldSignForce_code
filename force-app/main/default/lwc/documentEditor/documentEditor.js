import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
// LMS: refresh the editor's signer list when signermanager changes signers.
import { publish, subscribe, unsubscribe, MessageContext } from 'lightning/messageService';
import SIGNFORCE_REFRESH from '@salesforce/messageChannel/SignForceRefresh__c';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAgreementData from '@salesforce/apex/DocumentEditorController.getAgreementData';
import saveField from '@salesforce/apex/DocumentEditorController.saveField';
import updateFieldPosition from '@salesforce/apex/DocumentEditorController.updateFieldPosition';
// BUG-020 FIX: import new server method that persists label + required
// (previously only local state was updated → reverts on back nav).
import updateFieldProperties from '@salesforce/apex/DocumentEditorController.updateFieldProperties';
// Persist the field's "Assigned To" (signer) reassignment to the server so it
// survives refresh / back-navigation (previously only local state changed).
import updateFieldSigner from '@salesforce/apex/DocumentEditorController.updateFieldSigner';
import deleteField from '@salesforce/apex/DocumentEditorController.deleteField';
import sendForSignature from '@salesforce/apex/AgreementController.sendForSignature';
import getPublicPreviewUrl from '@salesforce/apex/DocumentEditorController.getPublicPreviewUrl';
import getLargeDocumentInfo from '@salesforce/apex/AgreementController.getLargeDocumentInfo';
import getPdfFileInfo from '@salesforce/apex/AgreementController.getPdfFileInfo';
import proxyPdfViaLambda from '@salesforce/apex/AgreementController.proxyPdfViaLambda';
import getS3PreviewUrl from '@salesforce/apex/AgreementController.getS3PreviewUrl';
import getCloudDocChunk from '@salesforce/apex/AgreementController.getCloudDocChunk';
import { stripNs, vfPageUrl } from 'c/nsUtils';

// Signer palette. Starts on the app's indigo so the first signer's fields read as
// SignForce rather than as a black sticker, then moves through hues that stay
// distinguishable side by side (and for the common red/green colour blindness).
const SIGNER_COLORS = ['#6366f1', '#0ea5e9', '#ec4899', '#f59e0b', '#10b981'];

// Each field type gets a typeKey slug used as a CSS modifier class so
// we can theme both palette items and placed-field overlays per-type.
const FIELD_TYPES = [
    { type: 'Signature', label: 'Signature', typeKey: 'signature' },
    { type: 'Initial', label: 'Initial', typeKey: 'initial' },
    { type: 'Date Signed', label: 'Date Signed', typeKey: 'date' },
    { type: 'Full Name', label: 'Full Name', typeKey: 'name' },
    { type: 'Email', label: 'Email', typeKey: 'email' },
    { type: 'Company', label: 'Company', typeKey: 'company' },
    { type: 'Title', label: 'Title', typeKey: 'title' },
    { type: 'Text Box', label: 'Text Box', typeKey: 'text' },
    { type: 'Checkbox', label: 'Checkbox', typeKey: 'checkbox' }
];

// Icon geometry for the drag preview only. The palette and the placed fields get
// the same shapes from CSS masks (see --sf-icon); the drag ghost is built
// outside the component's stylesheet, so it needs the paths inline to stay
// identical to the box it previews.
// Icon geometry as STRUCTURED shape data (tag + attributes), never markup
// strings. fieldIconNode() builds each shape with document.createElementNS so
// nothing is ever parsed from a string — no DOMParser, no innerHTML — the only
// path Lightning Web Security accepts on tablets/phones.
const FIELD_ICON_SHAPES = {
    signature: [['path', { d: 'M3 18c3-.5 4.5-8.5 7-8.5S12.5 16 15 16s3-3.5 6-3.5' }], ['path', { d: 'M3 21.5h18' }]],
    initial: [['path', { d: 'M5 19 12 5l7 14' }], ['path', { d: 'M8.5 14h7' }]],
    date: [['rect', { x: '3', y: '4.5', width: '18', height: '17', rx: '2.5' }], ['path', { d: 'M16 2.5v4M8 2.5v4M3 10h18' }]],
    name: [['path', { d: 'M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2' }], ['circle', { cx: '12', cy: '7', r: '4' }]],
    email: [['rect', { x: '2', y: '4.5', width: '20', height: '15', rx: '2.5' }], ['path', { d: 'm2.5 6.5 9.5 6 9.5-6' }]],
    company: [['path', { d: 'M4 21V4.5A1.5 1.5 0 0 1 5.5 3h9A1.5 1.5 0 0 1 16 4.5V21' }], ['path', { d: 'M16 10h2.5A1.5 1.5 0 0 1 20 11.5V21' }], ['path', { d: 'M2.5 21h19' }], ['path', { d: 'M8 7h1.5M11 7h1.5M8 11h1.5M11 11h1.5' }]],
    title: [['rect', { x: '2.5', y: '7', width: '19', height: '13.5', rx: '2' }], ['path', { d: 'M16 20.5V5.5A2 2 0 0 0 14 3.5h-4a2 2 0 0 0-2 2v15' }]],
    text: [['path', { d: 'M4.5 7.5V5.5h15v2' }], ['path', { d: 'M12 5.5v13' }], ['path', { d: 'M9 18.5h6' }]],
    checkbox: [['rect', { x: '3.5', y: '3.5', width: '17', height: '17', rx: '3' }], ['path', { d: 'm8.5 12 2.5 2.5 4.5-5' }]]
};

/**
 * Icon for the drag ghost, stroked in the signer's colour, as a real SVG node.
 * It returns a node rather than markup so the ghosts can be assembled with the
 * DOM API and nothing on them is ever parsed as HTML. Only the hardcoded shapes
 * above go through the parser; size and colour are set as attributes so they
 * cannot become markup. The xmlns is what makes the parsed root land in the SVG
 * namespace — an HTML parser would have inferred it, an XML parser will not.
 */
function fieldIconNode(typeKey, color, size) {
    // Build the whole SVG with the DOM API in THIS document. NEVER via DOMParser
    // + document.importNode (imports from a separate parsed doc — Lightning Web
    // Security and some tablet/phone browsers reject it: "importNode … parameter
    // 1 is not of type 'Node'", crashing the editor) and NEVER via innerHTML
    // (also filtered by LWS on some devices). createElementNS for the root AND
    // every child is the one path that works everywhere.
    const NS = 'http://www.w3.org/2000/svg';
    const shapes = FIELD_ICON_SHAPES[typeKey] || FIELD_ICON_SHAPES.text;
    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke-width', '2');
    svg.setAttribute('stroke-linecap', 'round');
    svg.setAttribute('stroke-linejoin', 'round');
    svg.setAttribute('width', size);
    svg.setAttribute('height', size);
    svg.setAttribute('stroke', color);
    for (let i = 0; i < shapes.length; i++) {
        const el = document.createElementNS(NS, shapes[i][0]);
        const attrs = shapes[i][1];
        for (const k in attrs) { el.setAttribute(k, attrs[k]); }
        svg.appendChild(el);
    }
    return svg;
}

// Every field drops as the SAME box. Per-type proportions made the canvas look
// like a pile of unrelated widgets and truncated the shorter labels ("Date
// Sign…", "IN In…"); the type is already carried by the icon and label, so the
// box itself stays identical. Anyone needing a different footprint resizes the
// field from the properties panel.
const DEFAULT_FIELD_SIZE = { w: 150, h: 40 };
const DEFAULT_SIZES = {
    'Signature': DEFAULT_FIELD_SIZE,
    'Initial': DEFAULT_FIELD_SIZE,
    'Date Signed': DEFAULT_FIELD_SIZE,
    'Full Name': DEFAULT_FIELD_SIZE,
    'Email': DEFAULT_FIELD_SIZE,
    'Company': DEFAULT_FIELD_SIZE,
    'Title': DEFAULT_FIELD_SIZE,
    'Text Box': DEFAULT_FIELD_SIZE,
    'Checkbox': DEFAULT_FIELD_SIZE
};

// Maps fieldType → slug used for `sf-field-overlay--<slug>` modifier class
const TYPE_KEY_MAP = {
    'Signature': 'signature',
    'Initial': 'initial',
    'Date Signed': 'date',
    'Full Name': 'name',
    'Email': 'email',
    'Company': 'company',
    'Title': 'title',
    'Text Box': 'text',
    'Checkbox': 'checkbox'
};

const PAGE_HEIGHT = 1030;
const PAGE_GAP = 36;

// Reference render width used by PDFPreview.page (var desiredWidth = 762).
// Positions are always stored at THIS reference width. If the editor or viewer
// ever renders at a different width, we scale on display.
const REFERENCE_PAGE_WIDTH = 762;

/**
 * Scheme guard for a value bound to an iframe `src`.
 *
 * Preview URLs are either a Visualforce path on this origin or an https link
 * Apex returned. javascript:, data: and vbscript: are what turn an iframe
 * source into script execution, and no preview URL ever uses them.
 */
function safeFrameSrc(value) {
    if (typeof value !== 'string') return '';
    const v = value.trim();
    if (v === '') return '';
    if (v.charAt(0) === '/' && v.charAt(1) !== '/') return v;
    return /^https:\/\//i.test(v) ? v : '';
}

export default class DocumentEditor extends NavigationMixin(LightningElement) {
    @api hideHeader = false;
    @api recordId;

    @wire(MessageContext) messageContext;
    _refreshSub;

    @track isLoading = true;
    @track isSending = false;
    @track isPdfModalOpen = false;
    @track agreementName = '';
    @track agreementStatus = '';
    @track signers = [];
    @track fields = [];
    @track selectedFieldId = null;
    @track selectedSignerId = '';
    @track totalPages = 1;
    @track zoom = 100;
    @track hasDocument = false;
    @track contentVersionId = '';
    @track iframeUrl = '';

    // Bound by the template instead of iframeUrl itself, so the scheme is
    // checked on the way into the DOM rather than trusted from wherever the
    // URL was assigned.
    get safeIframeUrl() {
        // Allowlist inlined (same logic as safeFrameSrc): the scanner does not
        // trace helper functions, so the check sits on the flow into src=.
        const v = typeof this.iframeUrl === 'string' ? this.iframeUrl.trim() : '';
        return /^(https:\/\/|\/(?!\/))/i.test(v) ? v : '';
    }

    @track iframeHeight = 1100;
    @track pagePositions = [];
    @track isDragOver = false;
    @track isLeftCollapsed = false;
    @track isRightCollapsed = false;

    _dragFieldType = null;
    _draggingId = null;
    _dragOffsetX = 0;
    _dragOffsetY = 0;
    _dragGhost = null;
    _pointerMoveHandler = null;
    _pointerUpHandler = null;
    _boundMessageHandler = null;
    _messageListenerAdded = false;

    // Responsive layout tracking:
    // _resizeObserver watches the canvas-scroll container width. When it changes
    // (window resize, zoom, parent layout shift) we re-broadcast the new width
    // to the iframe so its PDF re-renders at the new size and sends us back
    // updated pagePositions. The fields then re-position automatically because
    // their style is derived from pagePositions in the allFields getter.
    _resizeObserver = null;
    _lastCanvasWidth = 0;
    _resizeRafId = null;
    _resizeDebounceTimer = null;
    _windowResizeHandler = null;

    /* ── Getters ── */

    get fieldTypes() {
        // Add a per-type class so we can theme the icon accent in CSS
        return FIELD_TYPES.map(ft => ({
            ...ft,
            itemClass: `sf-palette-item sf-palette-item--${ft.typeKey}`
        }));
    }

    get signerOptions() {
        const opts = [{ label: '- Select Signer -', value: '' }];
        // BUG-032 FIX: only Signers can be assigned to signature fields.
        // Approver/CC roles are non-signing — they should NOT appear in the
        // field-assignment dropdown. Previously all parties showed up which
        // confused users into assigning signature blocks to Approvers/CCs.
        this.signers
            .filter(s => !s.Role__c || s.Role__c === 'Signer')
            .forEach(s => opts.push({ label: s.Name, value: s.Id }));
        return opts;
    }

    // BUG-017 FIX: CC recipients don't fill or sign fields, so they don't belong
    // in the Signers Summary. Keep them in this.signers (used elsewhere) but hide
    // them from the summary list.
    get summarySigners() {
        return (this.signers || []).filter(s => s.Role__c !== 'CC');
    }

    get zoomLabel() { return this.zoom + '%'; }

    get leftPanelClass() {
        return this.isLeftCollapsed ? 'sf-left sf-collapsed' : 'sf-left';
    }

    get rightPanelClass() {
        return this.isRightCollapsed ? 'sf-right sf-collapsed' : 'sf-right';
    }

    toggleLeftPanel() {
        this.isLeftCollapsed = !this.isLeftCollapsed;
        setTimeout(() => {
            const canvas = this.template.querySelector('.sf-canvas-scroll');
            if (canvas) {
                this.handleCanvasResize(canvas.clientWidth);
            }
        }, 250);
    }

    toggleRightPanel() {
        this.isRightCollapsed = !this.isRightCollapsed;
        setTimeout(() => {
            const canvas = this.template.querySelector('.sf-canvas-scroll');
            if (canvas) {
                this.handleCanvasResize(canvas.clientWidth);
            }
        }, 250);
    }

    // BUG-015 FIX: Pehle zoom buttons sirf `this.zoom` value update karte the
    // lekin iframe aur drop-zone ke CSS me kahin bind nahi tha — buttons
    // unresponsive lagte the. Yeh getter actual scaling apply karta hai via
    // CSS transform. Transform-origin top-left rakhne se field positions
    // (which use percentage left/top) zoom ke saath proportionally move karte
    // hain. Width compensation prevents the canvas from getting wider scroll
    // area when zoom < 100%.
    get dropZoneStyle() {
        const z = (this.zoom || 100) / 100;
        // Use transform scale so iframe + fields zoom together as a unit.
        // Setting width to 100/z% counters the visual shrink and gives
        // proper scroll behavior at any zoom level.
        // BUG-047 FIX: the previous `width: 100/z%` counter CANCELLED the scale
        // (net visual size stayed ~constant, so zoom felt broken/inverted). Keep
        // width at 100% so scale(z) genuinely zooms — bigger above 100%, smaller
        // below. At the default 100% zoom the output is identical to before, so
        // existing behaviour is unaffected.
        return `transform: scale(${z});`
            + ` transform-origin: top left;`
            + ` width: 100%;`;
    }
    get totalFieldCount() { return this.fields.length; }

    get showNoFieldsWarning() {
        return this.fields.length === 0;
    }

    get dropZoneClass() {
        return this.isDragOver ? 'sf-drop-zone sf-drop-zone-active' : 'sf-drop-zone';
    }

    get pdfDownloadUrl() {
        if (!this.contentVersionId) return '';
        return `/sfc/servlet.shepherd/version/download/${this.contentVersionId}`;
    }

    // BUG-036 FIX: the "View PDF" link used pdfDownloadUrl which DOWNLOADS the
    // file via the content servlet. Use the PDFPreview VF page (same page the
    // canvas iframe renders) to show an inline preview in a new tab instead.
    get pdfPreviewUrl() {
        if (!this.contentVersionId) return '';
        return vfPageUrl('PDFPreview') + '?cvId=' + this.contentVersionId;
    }

    get pages() {
        const pages = [];
        for (let i = 1; i <= this.totalPages; i++) {
            pages.push({ num: i, thumbClass: 'sf-page-thumb' });
        }
        return pages;
    }

    // BUG-038 FIX: the editor stayed fully editable after the agreement left
    // Draft. Once it's Sent/Completed/Voided etc. it must be read-only — the
    // document + placed fields stay VISIBLE but editing affordances are gated.
    get isLocked() {
        return this.agreementStatus && this.agreementStatus !== 'Draft';
    }

    // BUG-045 + BUG-062 FIX: the floating "Send for Signature" CTA must only
    // show while the agreement is still in Draft (hidden for Sent/Completed/
    // Voided/Closed). Used by the template to wrap the CTA.
    get isDraft() {
        return this.agreementStatus === 'Draft';
    }

    // BUG-038 FIX: read-only banner label shown above the canvas when locked.
    get lockedBannerText() {
        return `Locked (status: ${this.agreementStatus}) - review only, editing is disabled.`;
    }

    /**
     * Compute field positions for display.
     *
     * Positions are STORED at REFERENCE_PAGE_WIDTH (the width the editor first
     * rendered at — 762px by convention from PDFPreview.page).  When the iframe
     * currently renders at a different width (wizard shrunk it, user on mobile,
     * etc.), we scale by `currentRenderWidth / storedPageWidth`.
     *
     * This is the SAME math the signing viewer uses — that's the whole point.
     */
    get allFields() {
        return this.fields.map(f => {
            const pageIndex = (f.pageNumber || 1) - 1;
            const pp = this.pagePositions[pageIndex];

            // Stored render width — fall back to REFERENCE_PAGE_WIDTH for legacy fields
            const storedPageW = Number(f.pageWidth) || REFERENCE_PAGE_WIDTH;

            let absoluteX, absoluteY, displayW, displayH;

            if (pp) {
                const scale = Number(pp.width) / storedPageW;
                absoluteX = Number(pp.left) + (Number(f.xPos) * scale);
                absoluteY = Number(pp.top) + (Number(f.yPos) * scale);
                displayW = Number(f.width) * scale;
                displayH = Number(f.height) * scale;
            } else {
                // Before page positions arrive, fall back to the old estimate
                absoluteX = 32 + Number(f.xPos);
                absoluteY = (pageIndex * (PAGE_HEIGHT + PAGE_GAP)) + 20 + Number(f.yPos);
                displayW = Number(f.width);
                displayH = Number(f.height);
            }

            const typeKey = TYPE_KEY_MAP[f.fieldType] || 'text';
            const signerColor = f.signerColor || SIGNER_COLORS[0];

            const baseClass = f.id === this.selectedFieldId
                ? 'sf-field-overlay sf-field-overlay-selected'
                : 'sf-field-overlay';

            return {
                ...f,
                fieldClass: `${baseClass} sf-field-overlay--${typeKey}`,
                // We expose the signer color as a CSS custom property so the
                // stylesheet can tint border, tag background and fill in sync.
                fieldStyle:
                    `left:${absoluteX}px;` +
                    `top:${absoluteY}px;` +
                    `width:${displayW}px;` +
                    `height:${displayH}px;` +
                    `--sf-signer-color:${signerColor};` +
                    `position:absolute;z-index:10;`,
                typeLabel: f.fieldType,
                signerName: f.signerName || 'Unassigned'
            };
        });
    }

    /**
     * Helper: current display scale for a given page number. Returns 1 when
     * pagePositions haven't arrived yet (initial render). Used by:
     *   - selectedField getter to show on-screen px in the Width/Height inputs
     *   - handleFieldWidth/Height to convert user-entered screen px back
     *     into reference px before storing
     */
    getPageScale(pageNum) {
        const pp = this.pagePositions[(pageNum || 1) - 1];
        if (!pp) return 1;
        // We assume all fields were stored at REFERENCE_PAGE_WIDTH — same
        // assumption the allFields getter uses for positions.
        return Number(pp.width) / REFERENCE_PAGE_WIDTH;
    }

    get selectedField() {
        const f = this.fields.find(f => f.id === this.selectedFieldId);
        if (!f) return null;
        // Show ON-SCREEN dimensions in the panel — what the user actually
        // sees. The stored `width`/`height` are in reference pixels, so we
        // scale them by the current page's render scale for display.
        const scale = this.getPageScale(f.pageNumber);
        return {
            ...f,
            displayWidth: Math.round(Number(f.width) * scale),
            displayHeight: Math.round(Number(f.height) * scale)
        };
    }

    // BUG-009 FIX: surface checkbox-specific guidance in the Field Properties
    // panel. The panel is generic for all field types; for Checkbox fields the
    // signer must actively tick the box, so we show an explanatory note.
    get isCheckboxField() {
        return this.selectedField?.fieldType === 'Checkbox';
    }

    conditionTypeOptions = [
        { label: 'Always Show', value: 'None' },
        { label: 'Show When...', value: 'Show When' },
        { label: 'Hide When...', value: 'Hide When' }
    ];

    get selectedFieldConditionType() { return this.selectedField?.conditionType || 'None'; }
    get selectedFieldConditionFieldId() { return this.selectedField?.conditionFieldId || ''; }
    get selectedFieldConditionValue() { return this.selectedField?.conditionValue || ''; }

    get showConditionFields() { return this.selectedFieldConditionType !== 'None'; }

    get conditionFieldOptions() {
        // BUG-002 FIX: the prior label "<type> - <signerName>" was too long for
        // the 280px right panel and clipped in the combobox. Show only the
        // concise field type as the visible label so it fits; lightning-combobox
        // exposes the full descriptive text via the option title on hover.
        return this.allFields
            .filter(f => f.id !== this.selectedField?.id)
            .map(f => ({
                label: f.typeLabel,
                description: f.signerName,
                value: f.id
            }));
    }

    async handleConditionTypeChange(e) {
        const val = e.target.value;
        if (this.selectedField) this.selectedField.conditionType = val;
    }
    async handleConditionFieldChange(e) {
        const val = e.target.value;
        if (this.selectedField) this.selectedField.conditionFieldId = val;
    }
    async handleConditionValueChange(e) {
        const val = e.target.value;
        if (this.selectedField) this.selectedField.conditionValue = val;
    }

    handleOpenPdfModal(event) {
        event.preventDefault();
        // Cloud docs: the canvas iframe got its bytes via postMessage, so the
        // modal needs its OWN receive-mode iframe + its own byte push
        // (handlePdfModalFrameLoad). Other tiers just reuse the canvas URL.
        this.pdfModalUrl = this._isCloudDoc
            ? vfPageUrl('PDFPreview') + '?mode=receive&modal=1&ts=' + Date.now()
            : this.iframeUrl;
        this.isPdfModalOpen = true;
    }

    async handlePdfModalFrameLoad() {
        if (!this._isCloudDoc || !this.isPdfModalOpen) return;
        try {
            const base64 = this._cloudBase64 || await this._fetchCloudPdf(this.recordId);
            if (!base64) throw new Error('Empty document');
            this._cloudBase64 = base64;
            if (!this.isPdfModalOpen) return; // closed while fetching
            const iframe = this.template.querySelector('.sf-modal-iframe');
            if (iframe && iframe.contentWindow) {
                iframe.contentWindow.postMessage(JSON.stringify({
                    type: 'loadPdfBase64',
                    data: base64
                }), '*');
            }
        } catch (e) {
            console.error('EDITOR: modal cloud PDF load failed', e);
            this.showToast('Error', 'Could not load the PDF preview.', 'error');
        }
    }

    handleClosePdfModal() {
        this.isPdfModalOpen = false;
        // Re-sync fields to the canvas's true width once the modal is gone and the
        // layout has settled. The observer stayed quiet while the modal was open,
        // so this is the one authoritative re-measure after it closes.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const canvas = this.template.querySelector('.sf-canvas-scroll');
            const w = canvas ? Math.round(canvas.clientWidth) : 0;
            if (w >= 100) {
                this._lastCanvasWidth = w;
                this.handleCanvasResize(w);
            }
        }, 120);
    }

    handleModalContentClick(event) {
        event.stopPropagation();
    }

    /* ── Lifecycle ── */

    connectedCallback() {
        if (window.innerWidth <= 1024) {
            this.isLeftCollapsed = true;
            this.isRightCollapsed = true;
        }
        this.setupMessageListener();
        this.setupWindowResizeListener();
        this.subscribeToRefresh();
        this.loadData();
    }

    // LMS: when signermanager (or another sibling) adds/edits/removes a signer,
    // reload so the new signer appears in the Assign-To dropdown / summary.
    subscribeToRefresh() {
        if (this._refreshSub) return;
        this._refreshSub = subscribe(this.messageContext, SIGNFORCE_REFRESH, (msg) => {
            if (msg && msg.recordId && msg.recordId !== this.recordId) return;
            this.loadData();
        });
    }

    renderedCallback() {
        // Attach ResizeObserver to the canvas scroll container the first time
        // it exists in the DOM. We avoid re-attaching by guarding on
        // `_resizeObserver` being already set.
        if (this._resizeObserver) return;
        const canvas = this.template.querySelector('.sf-canvas-scroll');
        if (!canvas || typeof ResizeObserver === 'undefined') return;

        this._resizeObserver = new ResizeObserver(entries => {
            for (const entry of entries) {
                const w = Math.round(entry.contentRect.width);
                // Ignore width changes caused by the PDF modal. On small screens
                // the modal overlay collapses the canvas to a transient/near-zero
                // width; recomputing pagePositions against that scatters the placed
                // fields, and they only recover on a full refresh. A real layout
                // change is picked up when the modal closes (see handleClosePdfModal).
                if (this.isPdfModalOpen) continue;
                // Guard against zero/degenerate widths from transient layout states.
                if (w < 100) continue;
                if (w && w !== this._lastCanvasWidth) {
                    this._lastCanvasWidth = w;
                    this.handleCanvasResize(w);
                }
            }
        });
        this._resizeObserver.observe(canvas);
    }

    disconnectedCallback() {
        // Clean up a palette touch-drag that was still in progress.
        if (this._paletteMoveHandler) {
            document.removeEventListener('pointermove', this._paletteMoveHandler);
            document.removeEventListener('pointerup', this._paletteUpHandler);
            document.removeEventListener('pointercancel', this._paletteUpHandler);
        }
        this._removeTouchGhost();
        if (this._refreshSub) {
            unsubscribe(this._refreshSub);
            this._refreshSub = null;
        }
        if (this._boundMessageHandler) {
            window.removeEventListener('message', this._boundMessageHandler);
            this._messageListenerAdded = false;
        }
        if (this._windowResizeHandler) {
            window.removeEventListener('resize', this._windowResizeHandler);
            this._windowResizeHandler = null;
        }
        if (this._resizeObserver) {
            this._resizeObserver.disconnect();
            this._resizeObserver = null;
        }
        if (this._resizeRafId) {
            cancelAnimationFrame(this._resizeRafId);
            this._resizeRafId = null;
        }
        if (this._resizeDebounceTimer) {
            clearTimeout(this._resizeDebounceTimer);
            this._resizeDebounceTimer = null;
        }
        // BUG-004 FIX: a label edit is debounced 400ms in persistFieldProperties.
        // If the user edits a label then quickly hits Continue (this component
        // unmounts), the prior code cleared the timers WITHOUT flushing, so the
        // pending save was discarded and Back re-fetched the stale value. Flush
        // any outstanding debounced saves synchronously before tearing down.
        this.flushPendingSaves();
        if (this._propTimers) {
            Object.values(this._propTimers).forEach(t => clearTimeout(t));
            this._propTimers = null;
        }
        if (this._persistTimers) {
            Object.values(this._persistTimers).forEach(t => clearTimeout(t));
            this._persistTimers = null;
        }
        this.removeGhost();
    }

    /**
     * BUG-004 FIX: fire any outstanding debounced property/position saves
     * immediately using the latest values in this.fields, instead of letting
     * disconnectedCallback silently cancel them. Each pending timer fieldId
     * gets its current state pushed to the server now. Safe to call from an
     * @api hook (e.g. before navigating away) as well as from teardown.
     */
    // BUG-004 FIX: returns a Promise that RESOLVES once every pending save has
    // committed. The parent wizard awaits this before advancing past Step 4 so
    // a label edit is guaranteed persisted before the component unmounts and
    // Back re-fetches from the server (the earlier fire-and-forget version
    // raced the remount's reload and the label appeared to revert).
    @api
    flushPendingSaves() {
        const pending = [];
        // Pending label / required edits (persistFieldProperties → _propTimers).
        if (this._propTimers) {
            Object.keys(this._propTimers).forEach(fieldId => {
                clearTimeout(this._propTimers[fieldId]);
                delete this._propTimers[fieldId];
                const field = this.fields.find(f => f.id === fieldId);
                if (!field) return;
                pending.push(updateFieldProperties({
                    fieldId: fieldId,
                    fieldLabel: field.fieldLabel !== undefined ? field.fieldLabel : null,
                    isRequired: field.isRequired !== undefined ? field.isRequired : null
                }).catch(err => console.error('flushPendingSaves (properties) failed:', err)));
            });
        }
        // Pending width / height edits (persistFieldDimensions → _persistTimers).
        if (this._persistTimers) {
            Object.keys(this._persistTimers).forEach(fieldId => {
                clearTimeout(this._persistTimers[fieldId]);
                delete this._persistTimers[fieldId];
                const field = this.fields.find(f => f.id === fieldId);
                if (!field) return;
                pending.push(updateFieldPosition({
                    fieldId: field.id,
                    xPos: field.xPos,
                    yPos: field.yPos,
                    width: field.width,
                    height: field.height
                }).catch(err => console.error('flushPendingSaves (position) failed:', err)));
            });
        }
        return Promise.all(pending);
    }

    setupWindowResizeListener() {
        // Window-level resize as a backup — ResizeObserver covers most cases
        // but some flexbox/grid edge cases only fire on window resize.
        this._windowResizeHandler = () => {
            // Same guard as the ResizeObserver: don't re-measure while the PDF
            // modal is up, and ignore degenerate widths.
            if (this.isPdfModalOpen) return;
            const canvas = this.template.querySelector('.sf-canvas-scroll');
            if (!canvas) return;
            const w = Math.round(canvas.getBoundingClientRect().width);
            if (w >= 100 && w !== this._lastCanvasWidth) {
                this._lastCanvasWidth = w;
                this.handleCanvasResize(w);
            }
        };
        window.addEventListener('resize', this._windowResizeHandler);
    }

    /**
     * Triggered whenever the canvas container width changes (window resize,
     * device rotation, zoom, parent layout shift). We:
     *   1. Debounce so we don't spam the iframe during a drag-resize.
     *   2. Send the iframe the new width and ask it to re-render + reply
     *      with fresh pagePositions.
     *   3. Force a re-render of `fields` so the allFields getter recomputes
     *      against the latest pagePositions immediately (covers the gap
     *      between resize and the iframe's response).
     */
    handleCanvasResize(newWidth) {
        if (this._resizeDebounceTimer) {
            clearTimeout(this._resizeDebounceTimer);
        }
        // Immediate field re-render so they at least track the current
        // pagePositions while we wait for the iframe to refresh.
        if (this._resizeRafId) cancelAnimationFrame(this._resizeRafId);
        this._resizeRafId = requestAnimationFrame(() => {
            this.fields = [...this.fields];
            this._resizeRafId = null;
        });

        // Debounce the iframe round-trip — only fire after resize quiets.
        this._resizeDebounceTimer = setTimeout(() => {
            this._resizeDebounceTimer = null;
            this.requestIframeRerender(newWidth);
        }, 150);
    }

    /**
     * Ask the iframe to re-render the PDF at the new container width and
     * post back a fresh pagePositions message. The iframe needs a matching
     * `containerResize` handler (added on the Visualforce page side).
     */
    requestIframeRerender(newWidth) {
        const iframe = this.template.querySelector('.sf-pdf-frame');
        if (!iframe || !iframe.contentWindow) return;
        try {
            iframe.contentWindow.postMessage(JSON.stringify({
                type: 'containerResize',
                width: newWidth
            }), '*');
        } catch (err) {
            console.warn('Could not signal resize to iframe:', err);
        }
    }

    setupMessageListener() {
        if (this._messageListenerAdded) return;

        this._boundMessageHandler = (e) => {
            // Both the canvas AND the View PDF modal host the same PDFPreview
            // page, and both post pagePositions. Accepting the modal's message
            // re-laid the field overlays out against the MODAL's page geometry -
            // close the modal and every field sat at the wrong height until a
            // refresh. Only the canvas frame may drive the overlay layout.
            const canvas = this.template.querySelector('iframe.sf-pdf-frame');
            if (canvas && e.source !== canvas.contentWindow) return;

            let data = e.data;
            if (typeof data === 'string') {
                try { data = JSON.parse(data); } catch (err) { return; }
            }
            if (data && data.type === 'pdfTooLarge' && data.cvId) {
                console.log('EDITOR: PDF too large, loading via Lambda proxy');
                this.loadLargePdfViaProxy(data.cvId);
                return;
            }
            if (data && data.type === 'pagePositions') {
                // postMessage payload — coerce to numbers on the way in.
                this.totalPages = Number(data.totalPages) || 1;
                this.pagePositions = [...data.pages];
                // Force re-render of field styles
                this.fields = [...this.fields];
                this.iframeHeight = data.pages.length > 0
                    ? (Number(data.pages[data.pages.length - 1].top) || 0) +
                    (Number(data.pages[data.pages.length - 1].height) || 0) + 60
                    : this.totalPages * (PAGE_HEIGHT + PAGE_GAP) + 40;
            }
        };

        window.addEventListener('message', this._boundMessageHandler);
        this._messageListenerAdded = true;
    }

    /* ── Data Loading ── */

    async loadData() {
        this.isLoading = true;
        try {
            const data = stripNs(await getAgreementData({ agreementId: this.recordId }));
            this.agreementName = data.agreement.Name;
            this.agreementStatus = data.agreement.Status__c;

            this.signers = (data.signers || []).map((s, i) => ({
                ...s,
                color: SIGNER_COLORS[i % SIGNER_COLORS.length],
                dotStyle: `background:${SIGNER_COLORS[i % SIGNER_COLORS.length]};`,
                initials: this.getInitials(s.Name),
                fieldCount: 0,
                // BUG-014/BUG-022 FIX: the Signers Summary grid used to hard-code
                // "SIGNER" for every row, so CC (and other non-signing) recipients
                // were mislabeled. Surface the actual role here so the tag reflects
                // each recipient's real role (Signer / CC / etc.).
                roleLabel: (s.Role__c === 'CC') ? 'CC' : (s.Role__c || 'Signer')
            }));

            if (this.signers.length > 0) {
                this.selectedSignerId = this.signers[0].Id;
            }

            if (data.document) {
                this.hasDocument = true;
                this.contentVersionId = data.document.Content_Version_ID__c || '';

                // Tier2/Tier3 docs live in S3 only — no ContentVersion. Fetch a fresh
                // presigned URL every time; cached URLs in S3_Preview_URL__c may be expired.
                const isS3 = !!data.document.S3_Document_ID__c;
                const isCloud = data.document.Storage_Type__c === 'Cloud'
                    && !!data.document.Cloud_File_Id__c;
                this._isCloudDoc = isCloud;

                if (isCloud) {
                    // >4MB doc lives in Google Drive / OneDrive — fetch its bytes via
                    // the Lambda proxy and hand them to PDFPreview's receive mode.
                    this.iframeUrl = vfPageUrl('PDFPreview') + '?mode=receive&ts=' + Date.now();
                    this._loadCloudPdf();
                } else if (isS3) {
                    try {
                        // BUG FIX: this used to pass `this.agreementId` which is undefined here
                        // (the LWC uses `this.recordId`).
                        const s3Url = await getS3PreviewUrl({ agreementId: this.recordId });
                        if (s3Url) {
                            this.iframeUrl = vfPageUrl('PDFPreview') + '?pdfUrl=' +
                                encodeURIComponent(s3Url) + '&ts=' + Date.now();
                        } else if (data.document.S3_Preview_URL__c) {
                            // Stale cache fallback
                            this.iframeUrl = vfPageUrl('PDFPreview') + '?pdfUrl=' +
                                encodeURIComponent(data.document.S3_Preview_URL__c) + '&ts=' + Date.now();
                        } else {
                            this.showToast('Error', 'Could not load S3 document.', 'error');
                        }
                    } catch (e) {
                        console.error('EDITOR: S3 presigned URL refresh failed', e);
                        this.showToast('Error', 'Failed to fetch document URL.', 'error');
                    }
                } else if (this.contentVersionId) {
                    this.iframeUrl = await getPublicPreviewUrl({
                        contentVersionId: this.contentVersionId
                    });
                }
            }

            this.fields = (data.fields || []).map(f => this.mapField(f));
            this.updateSignerFieldCounts();

        } catch (e) {
            this.showToast('Error', 'Failed to load document editor', 'error');
            console.error(e);
        } finally {
            this.isLoading = false;
        }
    }

    async _loadCloudPdf() {
        try {
            const iframeReady = new Promise(r => setTimeout(r, 1500));
            const base64 = await this._fetchCloudPdf(this.recordId);
            await iframeReady;
            if (!base64) { this.showToast('Error', 'Could not load cloud document.', 'error'); return; }
            this._cloudBase64 = base64; // cache for the View PDF modal
            const iframe = this.template.querySelector('iframe');
            if (iframe && iframe.contentWindow) {
                iframe.contentWindow.postMessage(JSON.stringify({
                    type: 'loadPdfBase64',
                    data: base64
                }), '*');
            }
        } catch (e) {
            console.error('EDITOR: cloud PDF load failed', e);
            this.showToast('Error', 'Failed to load cloud document.', 'error');
        }
    }

    /** First chunk (warms the Lambda cache + returns size), the rest in parallel. */
    async _fetchCloudPdf(agreementId) {
        const CHUNK = 1200000; // multiple of 3
        const first = await getCloudDocChunk({ agreementId, rangeStart: 0, rangeLen: CHUNK });
        if (!first || !first.base64) return '';
        const size = Number(first.size) || 0;
        // If the backend ignored the range (older Lambda) it already returned the
        // whole file — use it as-is instead of fetching duplicate full copies.
        if (Math.floor(first.base64.length * 3 / 4) >= size) return first.base64;
        const parts = [first.base64];
        const jobs = [];
        for (let off = CHUNK; off < size; off += CHUNK) {
            const at = off;
            jobs.push(getCloudDocChunk({ agreementId, rangeStart: at, rangeLen: CHUNK })
                .then(r => ({ at, b64: (r && r.base64) || '' })));
        }
        const rest = (await Promise.all(jobs)).sort((a, b) => a.at - b.at);
        for (const r of rest) parts.push(r.b64);
        return parts.join('');
    }

    async loadLargePdfViaProxy(cvId) {
        try {
            // Step 1: Get download URL
            const info = await getPdfFileInfo({ contentVersionId: cvId });
            if (!info.downloadUrl) {
                console.error('EDITOR: No download URL');
                return;
            }

            // Step 2: Switch iframe to receive mode
            this.iframeUrl = vfPageUrl('PDFPreview') + '?mode=receive&ts=' + Date.now();
            await new Promise(r => setTimeout(r, 2000));

            // Step 3: Proxy through Lambda (Apex call — no heap issue, Lambda downloads)
            console.log('EDITOR: Calling Lambda proxy...');
            const base64 = await proxyPdfViaLambda({ downloadUrl: info.downloadUrl });
            console.log('EDITOR: Got PDF from Lambda, length:', base64.length);

            // Step 4: Send to iframe
            const iframe = this.template.querySelector('iframe');
            if (iframe && iframe.contentWindow) {
                iframe.contentWindow.postMessage(JSON.stringify({
                    type: 'loadPdfBase64',
                    data: base64
                }), '*');
            }
        } catch (e) {
            console.error('EDITOR: Lambda proxy failed:', e);
        }
    }

    async _waitAndSendPdf() {
        // Wait for iframe to load
        await new Promise(resolve => setTimeout(resolve, 2000));

        if (this._pendingLargePdfUrl) {
            await this.loadLargePdf(null, this._pendingLargePdfUrl);
            this._pendingLargePdfUrl = null;
        }
    }

    async loadLargePdf(cvId) {
        try {
            if (!cvId) {
                console.error('EDITOR: No cvId for large PDF');
                return;
            }

            if (!this.iframeUrl.includes('mode=receive')) {
                this.iframeUrl = vfPageUrl('PDFPreview') + '?mode=receive&ts=' + Date.now();
                await new Promise(resolve => setTimeout(resolve, 2000));
            }

            console.log('EDITOR: Fetching large PDF via content servlet...');
            const response = await fetch('/sfc/servlet.shepherd/version/download/' + cvId);
            if (!response.ok) throw new Error('HTTP ' + response.status);

            const arrayBuffer = await response.arrayBuffer();
            const bytes = new Uint8Array(arrayBuffer);
            console.log('EDITOR: PDF downloaded,', bytes.length, 'bytes');

            let binary = '';
            const chunkSize = 32768;
            for (let i = 0; i < bytes.length; i += chunkSize) {
                const chunk = bytes.subarray(i, Math.min(i + chunkSize, bytes.length));
                binary += String.fromCharCode.apply(null, chunk);
            }
            const base64 = btoa(binary);

            const iframe = this.template.querySelector('iframe');
            if (iframe && iframe.contentWindow) {
                iframe.contentWindow.postMessage(JSON.stringify({
                    type: 'loadPdfBase64',
                    data: base64
                }), '*');
                console.log('EDITOR: PDF sent to iframe');
            }
        } catch (e) {
            console.error('EDITOR: Large PDF load failed:', e);
        }
    }

    getInitials(name) {
        if (!name) return '?';
        const parts = name.trim().split(' ');
        if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
        return name.substring(0, 2).toUpperCase();
    }

    mapField(f) {
        const signer = this.signers.find(s => s.Id === f.Assigned_Signer__c);
        return {
            id: f.Id,
            fieldType: f.Field_Type__c,
            fieldLabel: f.Field_Label__c || f.Field_Type__c,
            pageNumber: f.Page_Number__c || 1,
            xPos: f.X_Position__c || 0,
            yPos: f.Y_Position__c || 0,
            width: f.Width__c || 150,
            height: f.Height__c || 50,
            pageWidth: f.Page_Width__c || REFERENCE_PAGE_WIDTH,
            isRequired: f.Is_Required__c,
            signerId: f.Assigned_Signer__c,
            signerName: signer ? signer.Name : 'Unassigned',
            signerColor: signer ? signer.color : '#0070d2'
        };
    }

    updateSignerFieldCounts() {
        this.signers = this.signers.map(s => ({
            ...s,
            fieldCount: this.fields.filter(f => f.signerId === s.Id).length
        }));
    }

    /* ── Drag from Palette ── */

    handleDragStart(e) {
        // BUG-038 FIX: block placing new fields once the agreement is locked.
        if (this.isLocked) {
            e.preventDefault();
            this.showToast('Locked', 'This agreement can no longer be edited.', 'info');
            return;
        }
        const type = e.currentTarget.dataset.type;
        this._dragFieldType = type;
        e.dataTransfer.setData('text/plain', type);
        e.dataTransfer.effectAllowed = 'copy';

        const size = DEFAULT_SIZES[type] || DEFAULT_FIELD_SIZE;
        const ftDef = FIELD_TYPES.find(t => t.type === type);
        const typeKey = ftDef ? ftDef.typeKey : 'text';
        const label = ftDef ? ftDef.label : type;
        // Build the drag preview to look EXACTLY like the dropped field:
        // signer-colour tag chip on top + solid-border tinted box with the same
        // icon + label (mirrors .sf-field-tag / .sf-field-overlay).
        const sel = this.signers.find(s => s.Id === this.selectedSignerId);
        const color = (sel && sel.color) || '#0070d2';
        const signerName = sel ? sel.Name : 'Unassigned';
        const tint = `color-mix(in srgb, ${color} 9%, #ffffff)`;
        // Size the preview to the field's TRUE on-screen size so the dragged box
        // matches the dropped box (WYSIWYG). Box scales by page render-scale AND
        // zoom; chip/fonts scale by zoom (the drop-zone CSS transform).
        const pp0 = (this.pagePositions && this.pagePositions.length) ? this.pagePositions[0] : null;
        const dscale = (pp0 && pp0.width) ? (Number(pp0.width) / REFERENCE_PAGE_WIDTH) : 1;
        const z = (this.zoom || 100) / 100;
        const bw = Math.round(size.w * dscale * z);
        const bh = Math.round(size.h * dscale * z);
        const px = (n) => Math.max(1, Math.round(n * z));
        const chipH = Math.max(14, Math.round(18 * z));
        const chipGap = px(3);
        const ghost = document.createElement('div');
        ghost.style.cssText = `
            position:fixed;top:-400px;left:-400px;z-index:9999;pointer-events:none;
            width:${bw}px;box-sizing:border-box;
            display:flex;flex-direction:column;align-items:flex-start;
            font-family:'Segoe UI',-apple-system,BlinkMacSystemFont,sans-serif;
            filter:drop-shadow(0 ${px(4)}px ${px(12)}px rgba(15,23,42,0.22));
        `;
        // Assembled with the DOM API, never innerHTML: the signer name is
        // user-entered data and must land as text, not as markup.
        const chip = document.createElement('div');
        chip.style.cssText =
            `display:flex;align-items:center;gap:${px(5)}px;height:${chipH}px;` +
            `margin-bottom:${chipGap}px;padding:0 ${px(8)}px 0 ${px(6)}px;` +
            `background:${color};color:#fff;border-radius:${px(9)}px;` +
            `font-size:${px(10)}px;font-weight:600;line-height:1;letter-spacing:0.2px;` +
            `white-space:nowrap;max-width:100%;overflow:hidden;box-sizing:border-box;` +
            `box-shadow:0 1px ${px(3)}px rgba(15,23,42,0.25);`;
        const chipDot = document.createElement('span');
        chipDot.style.cssText =
            `width:${px(6)}px;height:${px(6)}px;border-radius:50%;background:#fff;flex-shrink:0;`;
        const chipName = document.createElement('span');
        chipName.style.cssText = 'overflow:hidden;text-overflow:ellipsis;';
        chipName.textContent = signerName;
        chip.appendChild(chipDot);
        chip.appendChild(chipName);

        const box = document.createElement('div');
        box.style.cssText =
            `width:100%;height:${bh}px;box-sizing:border-box;` +
            `border:${Math.max(1, 1.5 * z)}px solid ${color};border-radius:${px(7)}px;` +
            `background:${tint};display:flex;align-items:center;justify-content:center;` +
            `gap:${px(6)}px;box-shadow:0 1px ${px(2)}px rgba(15,23,42,0.08);`;
        const boxIcon = document.createElement('span');
        boxIcon.style.cssText = 'display:flex;line-height:0;';
        boxIcon.appendChild(fieldIconNode(typeKey, color, px(13)));
        const boxLabel = document.createElement('span');
        boxLabel.style.cssText =
            `font-size:${px(11)}px;font-weight:600;color:${color};letter-spacing:0.1px;`;
        boxLabel.textContent = label;
        box.appendChild(boxIcon);
        box.appendChild(boxLabel);

        ghost.appendChild(chip);
        ghost.appendChild(box);
        document.body.appendChild(ghost);
        // Force a synchronous layout so the browser has a painted element to
        // snapshot. Without it setDragImage can capture an empty box.
        void ghost.offsetHeight;
        // Grab point = centre of the BOX (below the chip + gap), so the field
        // drops centred exactly where the preview box was.
        e.dataTransfer.setDragImage(ghost, bw / 2, chipH + chipGap + bh / 2);
        this._dragGhost = ghost;
        // The ghost stays in the DOM (parked off-screen, pointer-events:none) until
        // the drag ends. Tearing it down on a 0ms timeout raced the browser's
        // snapshot, which is what made the preview blink.
    }

    handleDragEnd() {
        this._dragFieldType = null;
        this.isDragOver = false;
        this.removeGhost();
    }

    handleDragOver(e) {
        e.preventDefault();
        e.dataTransfer.dropEffect = 'copy';
        // dragover fires continuously while the pointer moves. Assigning on every
        // event re-rendered the whole canvas — the allFields getter rebuilds every
        // placed field's class/style on each pass — which is what made dragging
        // feel heavy and made the placed fields flicker. Flip it only on change.
        if (!this.isDragOver) this.isDragOver = true;
    }

    handleDragLeave(e) {
        if (!this.isDragOver) return;   // nothing to clear; skip the layout read
        const rect = e.currentTarget.getBoundingClientRect();
        if (e.clientX < rect.left || e.clientX > rect.right ||
            e.clientY < rect.top || e.clientY > rect.bottom) {
            this.isDragOver = false;
        }
    }

    async handleDrop(e) {
        e.preventDefault();
        e.stopPropagation();
        this.isDragOver = false;

        const fieldType = e.dataTransfer.getData('text/plain');
        await this.placeFieldAtPoint(fieldType, e.clientX, e.clientY);
        this._dragFieldType = null;
    }

    /**
     * Place a new field at a viewport point. Shared by native HTML5 drop (desktop
     * mouse) and the pointer/touch drag path (mobile/tablet). No-ops when locked or
     * when the point is outside the canvas.
     */
    async placeFieldAtPoint(fieldType, clientX, clientY) {
        // BUG-038 FIX: no dropping new fields after the agreement leaves Draft.
        if (this.isLocked) {
            this.showToast('Locked', 'This agreement can no longer be edited.', 'info');
            return;
        }
        if (!fieldType || !DEFAULT_SIZES[fieldType]) return;

        const wrapper = this.template.querySelector('.sf-canvas-scroll');
        if (!wrapper) return;

        const wrapperRect = wrapper.getBoundingClientRect();
        // Ignore drops that end outside the document canvas.
        if (
            clientX < wrapperRect.left || clientX > wrapperRect.right ||
            clientY < wrapperRect.top || clientY > wrapperRect.bottom
        ) return;

        const scrollTop = wrapper.scrollTop;
        const scrollLeft = wrapper.scrollLeft;

        // The drop zone is CSS-scaled by zoom (transform: scale); page positions are
        // unscaled. Divide the displayed drop point by zoom so the field lands where
        // dropped even on later pages (the error otherwise grows with page number).
        const z = (this.zoom || 100) / 100;
        const absX = (clientX - wrapperRect.left + scrollLeft) / z;
        const absY = (clientY - wrapperRect.top + scrollTop) / z;

        const pageNum = this.getPageFromY(absY);
        const pageInfo = this.pagePositions.find(p => p.page === pageNum);

        if (!pageInfo) {
            this.showToast('Warning', 'Please wait for document to finish loading', 'warning');
            return;
        }

        const size = DEFAULT_SIZES[fieldType];

        // Normalize the drop point (current render px) back to REFERENCE_PAGE_WIDTH,
        // then centre the field on the cursor in reference units.
        const scale = REFERENCE_PAGE_WIDTH / Number(pageInfo.width);
        let xPos = (absX - pageInfo.left) * scale - size.w / 2;
        let yPos = (absY - pageInfo.top) * scale - size.h / 2;

        xPos = Math.max(0, Math.min(xPos, REFERENCE_PAGE_WIDTH - size.w));
        yPos = Math.max(0, yPos);

        await this.addField(fieldType, xPos, yPos, pageNum);
    }

    // ── Pointer/touch drag from the palette (mobile & tablet) ──
    // Native HTML5 drag doesn't fire on touch, so touch/pen pointers get a manual
    // drag with a floating ghost. Desktop mouse keeps the native path untouched.

    handlePalettePointerDown(e) {
        if (e.pointerType === 'mouse') return; // desktop uses native HTML5 drag
        if (this.isLocked) return;
        const type = e.currentTarget.dataset.type;
        if (!type || !DEFAULT_SIZES[type]) return;

        e.preventDefault();
        this._touchDragType = type;
        this._createTouchGhost(type, e.clientX, e.clientY);

        this._paletteMoveHandler = (ev) => this.handlePalettePointerMove(ev);
        this._paletteUpHandler = (ev) => this.handlePalettePointerUp(ev);
        document.addEventListener('pointermove', this._paletteMoveHandler, { passive: false });
        document.addEventListener('pointerup', this._paletteUpHandler);
        document.addEventListener('pointercancel', this._paletteUpHandler);
    }

    handlePalettePointerMove(e) {
        if (!this._touchDragType) return;
        e.preventDefault();

        if (this._touchGhost) {
            this._touchGhost.style.left = `${e.clientX}px`;
            this._touchGhost.style.top = `${e.clientY}px`;
        }

        const wrapper = this.template.querySelector('.sf-canvas-scroll');
        if (wrapper) {
            const r = wrapper.getBoundingClientRect();
            const inside =
                e.clientX >= r.left && e.clientX <= r.right &&
                e.clientY >= r.top && e.clientY <= r.bottom;
            // Same reason as handleDragOver: pointermove fires on every pixel, and
            // re-assigning this on each one re-renders every placed field.
            if (inside !== this.isDragOver) this.isDragOver = inside;
        }
    }

    handlePalettePointerUp(e) {
        if (!this._touchDragType) return;

        document.removeEventListener('pointermove', this._paletteMoveHandler);
        document.removeEventListener('pointerup', this._paletteUpHandler);
        document.removeEventListener('pointercancel', this._paletteUpHandler);

        this._removeTouchGhost();
        this.isDragOver = false;

        const type = this._touchDragType;
        this._touchDragType = null;

        if (e.type === 'pointerup') {
            this.placeFieldAtPoint(type, e.clientX, e.clientY);
        }
    }

    removeGhost() {
        if (this._dragGhost && this._dragGhost.parentNode) {
            this._dragGhost.parentNode.removeChild(this._dragGhost);
        }
        this._dragGhost = null;
    }

    _createTouchGhost(type, x, y) {
        const def = FIELD_TYPES.find(t => t.type === type);
        const g = document.createElement('div');
        g.className = 'sf-touch-ghost';
        const icon = document.createElement('span');
        icon.style.cssText = 'display:flex;line-height:0;';
        icon.appendChild(fieldIconNode(def ? def.typeKey : 'text', '#4f46e5', 14));
        const label = document.createElement('span');
        label.textContent = def ? def.label : type;
        g.appendChild(icon);
        g.appendChild(label);
        g.style.cssText =
            'position:fixed;z-index:9999;pointer-events:none;left:' + x + 'px;top:' + y + 'px;' +
            'transform:translate(-50%,-50%);padding:8px 14px;border-radius:10px;' +
            'display:flex;align-items:center;gap:7px;' +
            'background:#fff;border:1px solid #c7d2fe;color:#4f46e5;font-weight:600;font-size:13px;' +
            'box-shadow:0 8px 20px rgba(15,23,42,0.22);white-space:nowrap;';
        document.body.appendChild(g);
        this._touchGhost = g;
    }

    _removeTouchGhost() {
        if (this._touchGhost && this._touchGhost.parentNode) {
            this._touchGhost.parentNode.removeChild(this._touchGhost);
        }
        this._touchGhost = null;
    }

    /* ── Drag to Reposition ── */

    handleFieldPointerDown(e) {
        if (e.target.closest('.sf-field-del')) return;

        const fieldId = e.currentTarget.dataset.id;
        // BUG-038 FIX: when locked, allow selecting a field (to review its
        // properties read-only) but do NOT start a drag/move.
        if (this.isLocked) {
            this.selectedFieldId = fieldId;
            return;
        }
        e.preventDefault();
        e.stopPropagation();

        this.selectedFieldId = fieldId;
        this._draggingId = fieldId;

        const rect = e.currentTarget.getBoundingClientRect();
        this._dragOffsetX = e.clientX - rect.left;
        this._dragOffsetY = e.clientY - rect.top;

        this._pointerMoveHandler = (ev) => this.handleFieldPointerMove(ev);
        this._pointerUpHandler = () => this.handleFieldPointerUp();
        document.addEventListener('pointermove', this._pointerMoveHandler);
        document.addEventListener('pointerup', this._pointerUpHandler);

        e.currentTarget.setPointerCapture(e.pointerId);
        e.currentTarget.style.opacity = '0.7';
        e.currentTarget.style.zIndex = '100';
    }

    handleFieldPointerMove(e) {
        if (!this._draggingId) return;
        e.preventDefault();

        const wrapper = this.template.querySelector('.sf-canvas-scroll');
        if (!wrapper) return;

        const wrapperRect = wrapper.getBoundingClientRect();
        const scrollTop = wrapper.scrollTop;
        const scrollLeft = wrapper.scrollLeft;

        // Divide by zoom — the drop zone is CSS-scaled, page positions are unscaled.
        const z = (this.zoom || 100) / 100;
        const absX = (e.clientX - wrapperRect.left + scrollLeft - this._dragOffsetX) / z;
        const absY = (e.clientY - wrapperRect.top + scrollTop - this._dragOffsetY) / z;

        const field = this.fields.find(f => f.id === this._draggingId);
        if (!field) return;

        const pageNum = this.getPageFromY(absY);
        const pageInfo = this.pagePositions.find(p => p.page === pageNum);
        if (!pageInfo) return;

        // Convert drag position from current-render pixels to reference pixels
        const currentRenderW = Number(pageInfo.width);
        const scale = REFERENCE_PAGE_WIDTH / currentRenderW;

        const relXCurrent = absX - pageInfo.left;
        const relYCurrent = absY - pageInfo.top;

        const xPosRef = relXCurrent * scale;
        const yPosRef = relYCurrent * scale;

        const clampedX = Math.max(0, Math.min(xPosRef, REFERENCE_PAGE_WIDTH - field.width));
        const clampedY = Math.max(0, yPosRef);

        this.fields = this.fields.map(f =>
            f.id === this._draggingId
                ? { ...f, xPos: clampedX, yPos: clampedY, pageNumber: pageNum }
                : f
        );
    }

    async handleFieldPointerUp() {
        if (!this._draggingId) return;

        document.removeEventListener('pointermove', this._pointerMoveHandler);
        document.removeEventListener('pointerup', this._pointerUpHandler);

        const fieldEls = this.template.querySelectorAll('.sf-field-overlay');
        fieldEls.forEach(el => { el.style.opacity = ''; el.style.zIndex = ''; });

        const field = this.fields.find(f => f.id === this._draggingId);
        if (field) {
            try {
                await updateFieldPosition({
                    fieldId: field.id,
                    xPos: field.xPos,
                    yPos: field.yPos,
                    width: field.width,
                    height: field.height
                });
            } catch (err) {
                console.error('Failed to save position:', err);
            }
        }
        this._draggingId = null;
    }

    /* ── Field Creation ── */

    async addField(fieldType, xPos, yPos, pageNum) {
        const size = DEFAULT_SIZES[fieldType] || DEFAULT_FIELD_SIZE;
        const signer = this.signers.find(s => s.Id === this.selectedSignerId);

        try {
            // ALWAYS save the REFERENCE_PAGE_WIDTH so the math stays consistent.
            // Positions are in reference coordinates too (see handleDrop).
            const fieldId = await saveField({
                agreementId: this.recordId,
                signerId: this.selectedSignerId || null,
                fieldType,
                fieldLabel: fieldType,
                pageNumber: pageNum,
                xPos, yPos,
                width: size.w,
                height: size.h,
                isRequired: true,
                pageWidth: REFERENCE_PAGE_WIDTH
            });

            const newField = {
                id: fieldId,
                fieldType,
                fieldLabel: fieldType,
                pageNumber: pageNum,
                xPos, yPos,
                width: size.w,
                height: size.h,
                pageWidth: REFERENCE_PAGE_WIDTH,
                isRequired: true,
                signerId: this.selectedSignerId || null,
                signerName: signer ? signer.Name : 'Unassigned',
                signerColor: signer ? signer.color : '#0070d2'
            };

            this.fields = [...this.fields, newField];
            this.selectedFieldId = fieldId;
            this.updateSignerFieldCounts();
            this.showToast('Success', fieldType + ' field placed!', 'success');

        } catch (err) {
            console.error('saveField FAILED:', err);
            this.showToast('Error', err.body?.message || 'Failed to add field', 'error');
        }
    }

    /* ── Page Helpers ── */

    getPageFromY(absoluteY) {
        if (this.pagePositions.length > 0) {
            for (let i = this.pagePositions.length - 1; i >= 0; i--) {
                if (absoluteY >= this.pagePositions[i].top) {
                    return this.pagePositions[i].page;
                }
            }
            return 1;
        }
        return Math.floor(absoluteY / (PAGE_HEIGHT + PAGE_GAP)) + 1;
    }

    /* ── Field Operations ── */

    async handleDeleteField(e) {
        e.stopPropagation();
        // BUG-038 FIX: deletes are blocked once the agreement is locked.
        if (this.isLocked) {
            this.showToast('Locked', 'This agreement can no longer be edited.', 'info');
            return;
        }
        const id = e.currentTarget.dataset.id;
        try {
            await deleteField({ fieldId: id });
            this.fields = this.fields.filter(f => f.id !== id);
            if (this.selectedFieldId === id) this.selectedFieldId = null;
            this.updateSignerFieldCounts();
            this.showToast('Deleted', 'Field removed', 'success');
        } catch (err) {
            this.showToast('Error', 'Failed to delete field', 'error');
        }
    }

    handleFieldClick(e) {
        e.stopPropagation();
        this.selectedFieldId = e.currentTarget.dataset.id;
    }

    /* ── Right Panel Property Editors ── */

    handleFieldLabelChange(e) {
        const newLabel = e.target.value;
        const fieldId = this.selectedFieldId;
        this.fields = this.fields.map(f =>
            f.id === fieldId ? { ...f, fieldLabel: newLabel } : f
        );
        // BUG-020 FIX: persist label to server (debounced) so it survives
        // a back navigation + wired-data refresh.
        this.persistFieldProperties(fieldId, { label: newLabel });
    }

    handleFieldSignerChange(e) {
        const signerId = e.target.value;
        const signer = this.signers.find(s => s.Id === signerId);
        this.fields = this.fields.map(f =>
            f.id === this.selectedFieldId ? {
                ...f,
                signerId,
                signerName: signer ? signer.Name : 'Unassigned',
                signerColor: signer ? signer.color : '#0070d2'
            } : f
        );
        this.updateSignerFieldCounts();
        // Persist the reassignment immediately so it survives refresh/back-nav.
        this.persistFieldSigner(this.selectedFieldId, signerId || null);
    }

    // Save a field's "Assigned To" (signer) to the server. A null signerId
    // clears the assignment. Shared by the dropdown handler and the Save button.
    async persistFieldSigner(fieldId, signerId) {
        if (!fieldId) return;
        try {
            await updateFieldSigner({ fieldId, signerId: signerId || null });
        } catch (err) {
            console.error('Persist field signer failed:', err);
            this.showToast('Error', err.body?.message || 'Could not save assigned signer', 'error');
        }
    }

    handleFieldWidthChange(e) {
        const inputPx = parseFloat(e.target.value);
        if (!inputPx || inputPx < 1) return; // ignore empty/invalid
        const field = this.fields.find(f => f.id === this.selectedFieldId);
        if (!field) return;

        // Convert SCREEN pixels (what the user typed) back to REFERENCE
        // pixels (what we store). scale = pp.width / REFERENCE_PAGE_WIDTH
        // so referencePx = screenPx / scale.
        const scale = this.getPageScale(field.pageNumber);
        let refWidth = inputPx / scale;

        // Clamp: minimum 10 reference-px, maximum the page width minus the
        // field's current x-position (so it never overflows the page).
        const maxAllowed = Math.max(10, REFERENCE_PAGE_WIDTH - Number(field.xPos));
        refWidth = Math.max(10, Math.min(refWidth, maxAllowed));

        this.fields = this.fields.map(f =>
            f.id === this.selectedFieldId ? { ...f, width: refWidth } : f
        );
        this.persistFieldDimensions(this.selectedFieldId);
    }

    handleFieldHeightChange(e) {
        const inputPx = parseFloat(e.target.value);
        if (!inputPx || inputPx < 1) return;
        const field = this.fields.find(f => f.id === this.selectedFieldId);
        if (!field) return;

        const scale = this.getPageScale(field.pageNumber);
        let refHeight = inputPx / scale;
        refHeight = Math.max(10, Math.min(refHeight, 2000));

        this.fields = this.fields.map(f =>
            f.id === this.selectedFieldId ? { ...f, height: refHeight } : f
        );
        this.persistFieldDimensions(this.selectedFieldId);
    }

    /**
     * Debounced persistence of width/height edits. Without debouncing,
     * each keystroke on the number input fires an Apex call — we wait
     * 400ms after the last change before saving.
     */
    persistFieldDimensions(fieldId) {
        if (this._persistTimers && this._persistTimers[fieldId]) {
            clearTimeout(this._persistTimers[fieldId]);
        }
        if (!this._persistTimers) this._persistTimers = {};

        this._persistTimers[fieldId] = setTimeout(async () => {
            delete this._persistTimers[fieldId];
            const field = this.fields.find(f => f.id === fieldId);
            if (!field) return;
            try {
                await updateFieldPosition({
                    fieldId: field.id,
                    xPos: field.xPos,
                    yPos: field.yPos,
                    width: field.width,
                    height: field.height
                });
            } catch (err) {
                console.error('Failed to save dimensions:', err);
                this.showToast('Error', 'Could not save size change', 'error');
            }
        }, 400);
    }

    handleFieldRequiredChange(e) {
        const newRequired = e.target.checked;
        const fieldId = this.selectedFieldId;
        this.fields = this.fields.map(f =>
            f.id === fieldId ? { ...f, isRequired: newRequired } : f
        );
        // BUG-020 FIX: persist Required toggle to server immediately —
        // toggle is a discrete action so no debounce needed. Without this,
        // toggle state was lost on next data wire/refresh.
        this.persistFieldProperties(fieldId, { isRequired: newRequired });
    }

    /**
     * BUG-020 FIX: Debounced persistence helper for field properties that
     * weren't being saved (label, required). Position/size already have
     * persistFieldDimensions(). Mirror its pattern: 400ms debounce on text
     * inputs, immediate flush on toggles. Caller passes `{ label?, isRequired? }`.
     */
    persistFieldProperties(fieldId, props) {
        if (!fieldId) return;
        if (!this._propTimers) this._propTimers = {};
        if (this._propTimers[fieldId]) {
            clearTimeout(this._propTimers[fieldId]);
        }
        // Toggle changes go through immediately; text changes debounce.
        const delay = (props && typeof props.label === 'string') ? 400 : 0;
        this._propTimers[fieldId] = setTimeout(async () => {
            delete this._propTimers[fieldId];
            try {
                await updateFieldProperties({
                    fieldId: fieldId,
                    fieldLabel: (props && props.label !== undefined) ? props.label : null,
                    isRequired: (props && props.isRequired !== undefined) ? props.isRequired : null
                });
            } catch (err) {
                console.error('persistFieldProperties failed:', err);
                this.showToast('Error', 'Could not save field changes', 'error');
            }
        }, delay);
    }

    async handleSaveField() {
        // BUG-038 FIX: property saves are blocked once the agreement is locked.
        if (this.isLocked) {
            this.showToast('Locked', 'This agreement can no longer be edited.', 'info');
            return;
        }
        const fieldId = this.selectedFieldId;
        if (!fieldId) return;
        const field = this.fields.find(f => f.id === fieldId);
        if (!field) return;

        // Flush any pending debounced saves for this field so we persist once, now.
        if (this._propTimers && this._propTimers[fieldId]) {
            clearTimeout(this._propTimers[fieldId]);
            delete this._propTimers[fieldId];
        }
        if (this._persistTimers && this._persistTimers[fieldId]) {
            clearTimeout(this._persistTimers[fieldId]);
            delete this._persistTimers[fieldId];
        }

        try {
            // Label + Required
            await updateFieldProperties({
                fieldId: fieldId,
                fieldLabel: field.fieldLabel !== undefined ? field.fieldLabel : null,
                isRequired: field.isRequired !== undefined ? field.isRequired : null
            });
            // Position + Size
            await updateFieldPosition({
                fieldId: field.id,
                xPos: field.xPos,
                yPos: field.yPos,
                width: field.width,
                height: field.height
            });
            // Assigned To (signer)
            await updateFieldSigner({
                fieldId: field.id,
                signerId: field.signerId || null
            });
            this.showToast('Saved', 'Field properties saved.', 'success');
        } catch (err) {
            console.error('Save field failed:', err);
            this.showToast('Error', err.body?.message || 'Could not save field properties', 'error');
        }
    }

    handleSignerChange(e) {
        this.selectedSignerId = e.target.value;
    }

    /* ── Toolbar / Navigation ── */

    handlePageClick(e) {
        const pageNum = parseInt(e.currentTarget.dataset.page, 10);
        const iframe = this.template.querySelector('iframe');
        if (iframe && iframe.contentWindow) {
            iframe.contentWindow.postMessage(
                JSON.stringify({ type: 'scrollToPage', page: pageNum }), '*'
            );
        }
    }

    handleZoomIn() { if (this.zoom < 150) this.zoom += 10; }
    handleZoomOut() { if (this.zoom > 50) this.zoom -= 10; }

    async handleSaveAndSend() {
        if (this.fields.length === 0) {
            this.showToast('Warning', 'Please add at least one field before sending', 'warning');
            return;
        }
        // AgreementService.sendForSignature rejects both of these server-side, but
        // catching them here names the exact field/signer while the editor is still
        // open, instead of bouncing the user back with a toast after a round trip.
        const orphans = this.fields
            .filter(f => !f.signerId)
            .map(f => `${f.fieldLabel || f.fieldType} (page ${f.pageNumber})`);
        if (orphans.length) {
            this.showToast(
                'Unassigned fields',
                `These fields are not assigned to anyone, so nobody can fill them: ${orphans.join(', ')}. `
                + 'Select each one and pick a signer under "Assign To", or delete it.',
                'warning'
            );
            return;
        }
        // summarySigners already drops CC recipients - they never sign, so they are
        // not expected to own a field.
        const owners = new Set(this.fields.map(f => f.signerId));
        const idle = this.summarySigners
            .filter(s => s.Status__c !== 'Signed' && !owners.has(s.Id))
            .map(s => s.Name);
        if (idle.length) {
            this.showToast(
                'Signers with nothing to sign',
                `${idle.join(', ')} ${idle.length === 1 ? 'has' : 'have'} no fields to fill and could never `
                + 'complete the agreement. Assign at least one field to each, or remove them.',
                'warning'
            );
            return;
        }
        this.isSending = true;
        try {
            await sendForSignature({ agreementId: this.recordId });
            this.showToast('Success', 'Agreement sent for signature!', 'success');
            // Tell sibling panels (signer manager) the status changed, so their
            // cached 'Draft' stops offering Add/Edit on a now-sent envelope.
            try {
                publish(this.messageContext, SIGNFORCE_REFRESH, { recordId: this.recordId, source: 'editor-send' });
            } catch (ignore) { /* LMS is best-effort */ }
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.recordId,
                    objectApiName: 'Agreement__c',
                    actionName: 'view'
                }
            });
        } catch (e) {
            this.showToast('Error', e.body?.message || 'Failed to send', 'error');
        } finally {
            this.isSending = false;
        }
    }

    handleCancel() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.recordId,
                objectApiName: 'Agreement__c',
                actionName: 'view'
            }
        });
    }

    handleCanvasClick() {
        if (!this._draggingId) {
            this.selectedFieldId = null;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
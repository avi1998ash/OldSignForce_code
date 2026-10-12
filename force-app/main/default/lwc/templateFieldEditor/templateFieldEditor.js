import { LightningElement, api, track } from 'lwc';
// Reuse ONLY the DOCX->PDF preview-url builder from the proven editor controller.
// No Agreement-scoped Apex (getAgreementData/saveField/updateField*/deleteField/
// sendForSignature) is imported — a template has no Agreement and persists into
// the layout JSON fields[] managed by the parent (templateLibrary), not into
// Signature_Field__c at design time.
import getPublicPreviewUrl from '@salesforce/apex/DocumentEditorController.getPublicPreviewUrl';

const SIGNER_COLORS = ['#7c3aed', '#2e844a', '#ba0517', '#f5a623', '#1a73e8', '#0b7285'];

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

// DocuSign-style proportions (reference pixels at REFERENCE_PAGE_WIDTH).
const DEFAULT_SIZES = {
    'Signature': { w: 150, h: 40 },
    'Initial': { w: 64, h: 40 },
    'Date Signed': { w: 110, h: 30 },
    'Full Name': { w: 150, h: 30 },
    'Email': { w: 165, h: 30 },
    'Company': { w: 150, h: 30 },
    'Title': { w: 120, h: 30 },
    'Text Box': { w: 175, h: 38 },
    'Checkbox': { w: 22, h: 22 }
};

// Maps fieldType -> slug used for `sf-field-overlay--<slug>` modifier class
// Icon geometry for the drag previews only. The palette and the placed fields get
// the same shapes from CSS masks (see --sf-icon); the ghosts are built outside
// the stylesheet, so they need the paths inline to stay identical.
// Icon geometry as STRUCTURED shape data (tag + attributes), never markup
// strings. fieldIconNode() builds each shape with document.createElementNS so
// nothing is ever parsed from a string — no DOMParser, no innerHTML — which is
// the only path Lightning Web Security accepts on tablets/phones.
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
 * Icon for a drag ghost, stroked in the signer's colour, as a real SVG node.
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

// Reference render width used by PDFPreview.page (desiredWidth = 762).
// Positions are stored at THIS reference width and scaled on display.
const REFERENCE_PAGE_WIDTH = 762;

// Furthest a tag may sit from a field and still be treated as its anchor
// (762-ref units; a page is ~986 tall). Beyond this the tag is not describing
// where the field belongs, so the field keeps its absolute position instead.
const MAX_ANCHOR_DISTANCE = 500;

/**
 * X of a character sitting `within` characters into a pdf.js text run.
 *
 * pdf.js reports ONE origin for a whole run, so a tag starting mid-run would
 * otherwise be recorded at the run's start. That matters because runs are split
 * differently in the template and in the merged document — a merged value joins
 * with the text around it into a single run. Measuring the anchor and the resolved
 * position from different points offsets the field by the width of whatever text
 * precedes it on that line, which is small enough to slip past the sanity guard.
 *
 * Interpolating across the run's advance width is an approximation for
 * proportional faces, but it is accurate to a few px and far better than 0.
 * generateDocument._findValuePosition MUST use the same formula.
 */
function xWithinRun(item, within) {
    const len = String((item && item.str) || '').length;
    if (!len || !within) return (item && item.x) || 0;
    return (item.x || 0) + (item.w || 0) * (within / len);
}

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

export default class TemplateFieldEditor extends LightningElement {
    /* ── Public API ── */

    // ContentVersion Id of the template DOCX (preview url is DOCX->PDF converted).
    @api
    get templateFileId() { return this._templateFileId; }
    set templateFileId(val) {
        this._templateFileId = val;
        this.loadPreview();
    }

    // Array<{label, value}> where value = signer "key" (from templateLibrary
    // signerRows). Drives the per-field "Assign To" combobox.
    @api
    get signerOptions() { return this._signerOptions; }
    set signerOptions(val) {
        this._signerOptions = Array.isArray(val) ? val : [];

        // One signer means there is no decision to make, so make it. Without this
        // a single-signer template still drops fields as "Unassigned" and warns
        // about them at save time, which is a question with only one answer.
        if (this._signerOptions.length === 1) {
            this.selectedSignerKey = this._signerOptions[0].value;
        } else if (
            this.selectedSignerKey &&
            !this._signerOptions.some(o => o.value === this.selectedSignerKey)
        ) {
            // The signer this was defaulting to has been renamed away or deleted.
            this.selectedSignerKey = '';
        }

        // Refresh derived signer metadata (colors / names) on placed fields.
        this.refreshSignerMeta();
    }

    // Array of placement objects (the layout fields[]) to render on load.
    @api
    get initialFields() { return this._initialFields; }
    set initialFields(val) {
        this._initialFields = Array.isArray(val) ? val : [];
        this.hydrateFields();
    }

    /* ── Internal state ── */

    _templateFileId = null;
    _signerOptions = [];
    _initialFields = [];

    @track fields = [];               // internal field shape (see mapFromPlacement)
    @track selectedFieldId = null;
    @track selectedSignerKey = '';    // palette "Assign To" default for new fields
    @track showAssignPrompt = false;  // "who is this field for?" after a drop
    _pendingAssignId = null;          // the field waiting on that answer
    @track totalPages = 1;
    @track zoom = 100;
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
    @track hasDocument = false;
    @track isPreviewLoading = false;  // spinner until the iframe reports its pages
    @track previewError = false;      // preview URL fetch failed -> retry affordance
    @track isLeftCollapsed = false;
    @track isRightCollapsed = false;
    
    _rootResizeObserver = null;
    _initialCollapseDone = false;

    _localIdSeq = 1;
    _dragFieldType = null;
    _draggingId = null;
    _dragOffsetX = 0;
    _dragOffsetY = 0;
    _dragGhost = null;
    _pointerMoveHandler = null;
    _pointerUpHandler = null;
    _boundMessageHandler = null;
    _messageListenerAdded = false;
    _tagAnchors = [];   // merge-tag positions from the preview (762-ref), for field anchoring
    _fieldsHydrated = false;

    // Responsive layout tracking (re-broadcast width to iframe on resize).
    _resizeObserver = null;
    _lastCanvasWidth = 0;
    _resizeRafId = null;
    _resizeDebounceTimer = null;
    _windowResizeHandler = null;

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

    /* ── Getters ── */

    get fieldTypes() {
        return FIELD_TYPES.map(ft => ({
            ...ft,
            itemClass: `sf-palette-item sf-palette-item--${ft.typeKey}`
        }));
    }

    // Palette "Assign To" combobox options: prepend a blank choice to the
    // signer keys provided by the parent.
    get assignOptions() {
        const opts = [{ label: '- Select Signer -', value: '' }];
        this._signerOptions.forEach(o => opts.push({ label: o.label, value: o.value }));
        return opts;
    }

    get hasSigners() {
        return this._signerOptions && this._signerOptions.length > 0;
    }

    get zoomLabel() { return this.zoom + '%'; }

    get dropZoneStyle() {
        const z = (this.zoom || 100) / 100;
        return `transform: scale(${z});`
            + ` transform-origin: top left;`
            + ` width: 100%;`;
    }

    get totalFieldCount() { return this.fields.length; }
    get showNoFieldsWarning() { return this.fields.length === 0; }

    get dropZoneClass() {
        return this.isDragOver ? 'sf-drop-zone sf-drop-zone-active' : 'sf-drop-zone';
    }

    get pages() {
        const pages = [];
        for (let i = 1; i <= this.totalPages; i++) {
            pages.push({ num: i, thumbClass: 'sf-page-thumb' });
        }
        return pages;
    }

    /**
     * Compute field positions for display. Positions are STORED at
     * REFERENCE_PAGE_WIDTH; when the iframe renders at a different width we
     * scale by currentRenderWidth / storedPageWidth (same math the editor
     * and signing viewer use).
     */
    get allFields() {
        return this.fields.map(f => {
            const pageIndex = (f.pageNumber || 1) - 1;
            const pp = this.pagePositions[pageIndex];
            const storedPageW = Number(f.pageWidth) || REFERENCE_PAGE_WIDTH;

            let absoluteX, absoluteY, displayW, displayH;

            if (pp) {
                const scale = Number(pp.width) / storedPageW;
                absoluteX = Number(pp.left) + (Number(f.xPos) * scale);
                absoluteY = Number(pp.top) + (Number(f.yPos) * scale);
                displayW = Number(f.width) * scale;
                displayH = Number(f.height) * scale;
            } else {
                absoluteX = 32 + Number(f.xPos);
                absoluteY = (pageIndex * (PAGE_HEIGHT + PAGE_GAP)) + 20 + Number(f.yPos);
                displayW = Number(f.width);
                displayH = Number(f.height);
            }

            const typeKey = TYPE_KEY_MAP[f.fieldType] || 'text';
            const ftDef = FIELD_TYPES.find(t => t.type === f.fieldType);
            const signerColor = f.signerColor || '#94a3b8';

            const baseClass = f.id === this.selectedFieldId
                ? 'sf-field-overlay sf-field-overlay-selected'
                : 'sf-field-overlay';

            return {
                ...f,
                fieldClass: `${baseClass} sf-field-overlay--${typeKey}`,
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

    getPageScale(pageNum) {
        const pp = this.pagePositions[(pageNum || 1) - 1];
        if (!pp) return 1;
        return Number(pp.width) / REFERENCE_PAGE_WIDTH;
    }

    get selectedField() {
        const f = this.fields.find(x => x.id === this.selectedFieldId);
        if (!f) return null;
        const scale = this.getPageScale(f.pageNumber);
        return {
            ...f,
            displayWidth: Math.round(Number(f.width) * scale),
            displayHeight: Math.round(Number(f.height) * scale)
        };
    }

    get isCheckboxField() {
        return this.selectedField && this.selectedField.fieldType === 'Checkbox';
    }

    /* ── Lifecycle ── */

    connectedCallback() {
        if (window.innerWidth <= 1024) {
            this.isLeftCollapsed = true;
            this.isRightCollapsed = true;
        }
        this.setupMessageListener();
        this.setupWindowResizeListener();
        this.hydrateFields();
        this.loadPreview();
    }

    renderedCallback() {
        // Observe root editor width to auto-collapse sidebars when constrained (e.g. in modals)
        const root = this.template.querySelector('.sf-editor-root');
        if (root && !this._rootResizeObserver && typeof ResizeObserver !== 'undefined') {
            this._rootResizeObserver = new ResizeObserver(entries => {
                for (const entry of entries) {
                    const w = Math.round(entry.contentRect.width);
                    if (w && w < 850 && !this._initialCollapseDone) {
                        this.isLeftCollapsed = true;
                        this.isRightCollapsed = true;
                        this._initialCollapseDone = true;
                    }
                }
            });
            this._rootResizeObserver.observe(root);
        }

        if (this._resizeObserver) return;
        const canvas = this.template.querySelector('.sf-canvas-scroll');
        if (!canvas || typeof ResizeObserver === 'undefined') return;

        this._resizeObserver = new ResizeObserver(entries => {
            for (const entry of entries) {
                const w = Math.round(entry.contentRect.width);
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
        this._clearPreviewTimeout();
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
        if (this._rootResizeObserver) {
            this._rootResizeObserver.disconnect();
            this._rootResizeObserver = null;
        }
        if (this._resizeRafId) {
            cancelAnimationFrame(this._resizeRafId);
            this._resizeRafId = null;
        }
        if (this._resizeDebounceTimer) {
            clearTimeout(this._resizeDebounceTimer);
            this._resizeDebounceTimer = null;
        }
        this.removeGhost();
    }

    /* ── Preview / iframe ── */

    async loadPreview() {
        const cvId = this._templateFileId;
        if (!cvId) {
            this.hasDocument = false;
            this.iframeUrl = '';
            this.isPreviewLoading = false;
            this.previewError = false;
            this._clearPreviewTimeout();
            return;
        }
        // Show the spinner from the moment we start fetching, and keep it up until
        // the iframe actually reports rendered pages (first 'pagePositions'). The
        // iframe mounts underneath the overlay, so it loads/renders while covered.
        this.isPreviewLoading = true;
        this.previewError = false;
        this._previewReady = false;
        this._armPreviewTimeout();
        try {
            const url = await getPublicPreviewUrl({ contentVersionId: cvId });
            if (!url) throw new Error('empty preview url');
            // Ask PDFPreview to also report text positions so we can bind fields
            // to merge tags (anchor mode). Falls back cleanly if none are found.
            this.iframeUrl = url + (url.indexOf('?') === -1 ? '?' : '&') + 'sfAnchor=1';
            this.hasDocument = true;
        } catch (e) {
            // eslint-disable-next-line no-console
            console.error('templateFieldEditor: preview url failed', e);
            this.hasDocument = false;
            this.isPreviewLoading = false;
            this.previewError = true;
            this._clearPreviewTimeout();
        }
    }

    handleRetryPreview() {
        this.loadPreview();
    }

    /* Reveal the document once the iframe confirms it drew its pages. Idempotent —
       only the first pagePositions message clears the spinner. */
    markPreviewReady() {
        if (this._previewReady) return;
        this._previewReady = true;
        this.isPreviewLoading = false;
        this.previewError = false;
        this._clearPreviewTimeout();
    }

    _armPreviewTimeout() {
        this._clearPreviewTimeout();
        // Safety net: if the iframe never posts pages (blocked postMessage, very
        // slow render), stop spinning after a bounded wait and show what's there.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._previewTimeout = setTimeout(() => {
            this.isPreviewLoading = false;
            this._previewTimeout = null;
        }, 20000);
    }

    _clearPreviewTimeout() {
        if (this._previewTimeout) {
            clearTimeout(this._previewTimeout);
            this._previewTimeout = null;
        }
    }

    setupMessageListener() {
        if (this._messageListenerAdded) return;
        this._boundMessageHandler = (e) => {
            let data = e.data;
            if (typeof data === 'string') {
                try { data = JSON.parse(data); } catch (err) { return; }
            }
            if (data && data.type === 'pagePositions') {
                // postMessage payload — coerce to numbers on the way in.
                this.totalPages = Number(data.totalPages) || 1;
                this.pagePositions = [...data.pages];
                // Force re-render of field styles against fresh positions.
                this.fields = [...this.fields];
                this.iframeHeight = data.pages.length > 0
                    ? (Number(data.pages[data.pages.length - 1].top) || 0) +
                      (Number(data.pages[data.pages.length - 1].height) || 0) + 60
                    : this.totalPages * (PAGE_HEIGHT + PAGE_GAP) + 40;
                // The iframe has rendered — drop the loading overlay.
                this.markPreviewReady();
            }
            if (data && data.type === 'textItems') {
                this._tagAnchors = this.reassembleTags(data.items || []);
                // Bind every already-placed field to its nearest tag now that we
                // know where the tags are.
                this.refreshAnchors();
            }
        };
        window.addEventListener('message', this._boundMessageHandler);
        this._messageListenerAdded = true;
    }

    /* ── Merge-tag anchoring ──────────────────────────────────────────────
       pdf.js splits text into runs, so a "{{Tag}}" may arrive as several
       items on one line. Reassemble per line, locate every {{...}}, and record
       its 762-ref start position + a per-name occurrence index (reading order),
       so the same tag can be matched in the merged document at generation. */
    reassembleTags(items) {
        const lines = {};
        (items || []).forEach((it) => {
            if (!it || !it.str) return;
            const key = it.page + ':' + Math.round((it.y || 0) / 3);
            (lines[key] = lines[key] || []).push(it);
        });
        const tags = [];
        Object.keys(lines).forEach((k) => {
            const lineItems = lines[k].slice().sort((a, b) => (a.x || 0) - (b.x || 0));
            let combined = '';
            const charItem = [];
            const charOff = [];
            lineItems.forEach((it, idx) => {
                let n = 0;
                for (const ch of String(it.str)) { combined += ch; charItem.push(idx); charOff.push(n++); }
            });
            const re = /\{\{([^{}]+)\}\}/g;
            let m;
            while ((m = re.exec(combined)) !== null) {
                const it = lineItems[charItem[m.index]];
                if (it) {
                    tags.push({
                        name: m[1].trim(),
                        x: xWithinRun(it, charOff[m.index]),
                        y: it.y,
                        page: it.page
                    });
                }
            }
        });
        tags.sort((a, b) => a.page - b.page || a.y - b.y || a.x - b.x);
        const occ = {};
        tags.forEach((t) => { t.occurrence = (occ[t.name] || 0); occ[t.name] = t.occurrence + 1; });
        return tags;
    }

    /**
     * Nearest tag anchor for a point — SAME PAGE ONLY.
     *
     * Never fall back to another page's tag. An anchor means "this field belongs
     * beside that content", which cannot be true across a page boundary, and at
     * generation the field is moved to wherever its tag ended up: a field placed on
     * page 7 anchored to a page-10 tag was being relocated onto page 11.
     *
     * A field with no tag on its page simply stays unanchored and keeps its
     * absolute position, which is the safe outcome.
     */
    findAnchor(fx, fy, page) {
        if (!this._tagAnchors || !this._tagAnchors.length) return null;
        const pool = this._tagAnchors.filter((t) => t.page === page);
        if (!pool.length) return null;
        let best = null, bestD = Infinity;
        pool.forEach((t) => {
            const d = Math.hypot((t.x || 0) - fx, (t.y || 0) - fy);
            if (d < bestD) { bestD = d; best = t; }
        });
        // A tag most of a page away is not describing this field's position either.
        if (!best || bestD > MAX_ANCHOR_DISTANCE) return null;
        return {
            tag: best.name, occ: best.occurrence, page: best.page,
            dx: fx - best.x, dy: fy - best.y
        };
    }

    /** Re-emit placements so each field picks up its anchor now that we know
        where the tags are. toPlacement() does the actual (re)binding. */
    refreshAnchors() {
        if (this._tagAnchors && this._tagAnchors.length && this.fields.length) {
            this.emitChange();
        }
    }

    setupWindowResizeListener() {
        this._windowResizeHandler = () => {
            const canvas = this.template.querySelector('.sf-canvas-scroll');
            if (!canvas) return;
            const w = Math.round(canvas.getBoundingClientRect().width);
            if (w && w !== this._lastCanvasWidth) {
                this._lastCanvasWidth = w;
                this.handleCanvasResize(w);
            }
        };
        window.addEventListener('resize', this._windowResizeHandler);
    }

    handleCanvasResize(newWidth) {
        if (this._resizeDebounceTimer) clearTimeout(this._resizeDebounceTimer);
        if (this._resizeRafId) cancelAnimationFrame(this._resizeRafId);
        this._resizeRafId = requestAnimationFrame(() => {
            this.fields = [...this.fields];
            this._resizeRafId = null;
        });
        this._resizeDebounceTimer = setTimeout(() => {
            this._resizeDebounceTimer = null;
            this.requestIframeRerender(newWidth);
        }, 150);
    }

    requestIframeRerender(newWidth) {
        const iframe = this.template.querySelector('.sf-pdf-frame');
        if (!iframe || !iframe.contentWindow) return;
        try {
            iframe.contentWindow.postMessage(JSON.stringify({
                type: 'containerResize',
                width: newWidth
            }), '*');
        } catch (err) {
            // eslint-disable-next-line no-console
            console.warn('Could not signal resize to iframe:', err);
        }
    }

    /* ── Field hydration / mapping ── */

    // Translate a layout placement object into the internal field shape.
    mapFromPlacement(p, idx) {
        const sized = DEFAULT_SIZES[p.type] || { w: 150, h: 40 };
        const meta = this.signerMetaForKey(p.signerKey);
        return {
            id: `tf-${idx}-${this._localIdSeq++}`,
            fieldType: p.type,
            fieldLabel: p.label || p.type,
            pageNumber: Number(p.page) || 1,
            xPos: Number(p.x) || 0,
            yPos: Number(p.y) || 0,
            width: (p.width !== undefined && p.width !== null) ? Number(p.width)
                   : ((p.w !== undefined && p.w !== null) ? Number(p.w) : sized.w),
            height: (p.height !== undefined && p.height !== null) ? Number(p.height)
                    : ((p.h !== undefined && p.h !== null) ? Number(p.h) : sized.h),
            pageWidth: Number(p.pageWidth) || REFERENCE_PAGE_WIDTH,
            isRequired: p.required !== undefined ? !!p.required : true,
            signerKey: p.signerKey || '',
            // Carry any stored merge-tag anchor so a re-save keeps it even if the
            // preview hasn't been re-analysed yet.
            anchorTag: p.anchorTag || null,
            anchorOcc: (p.anchorOcc !== undefined && p.anchorOcc !== null) ? Number(p.anchorOcc) : null,
            anchorPage: (p.anchorPage !== undefined && p.anchorPage !== null) ? Number(p.anchorPage) : null,
            anchorDx: (p.anchorDx !== undefined && p.anchorDx !== null) ? Number(p.anchorDx) : null,
            anchorDy: (p.anchorDy !== undefined && p.anchorDy !== null) ? Number(p.anchorDy) : null,
            signerName: meta.name,
            signerColor: meta.color
        };
    }

    // Build a layout placement object from an internal field. THIS is the exact
    // JSON shape persisted into Template_Layout_JSON__c fields[] and consumed by
    // TemplateService.materializeSignersAndFields.
    toPlacement(f) {
        // Keys MUST match TemplateService.materializeSignersAndFields, which reads
        // 'width'/'height'/'pageWidth' (NOT 'w'/'h') — see TemplateServiceTest.
        // Geometry is in REFERENCE_PAGE_WIDTH (762) reference px, same convention
        // as documentEditor → Signature_Field__c (X/Y/Width/Height + Page_Width__c).
        const base = {
            type: f.fieldType,
            label: f.fieldLabel,
            page: Number(f.pageNumber) || 1,
            x: Number(f.xPos) || 0,
            y: Number(f.yPos) || 0,
            width: Number(f.width) || 0,
            height: Number(f.height) || 0,
            pageWidth: Number(f.pageWidth) || REFERENCE_PAGE_WIDTH,
            required: !!f.isRequired,
            signerKey: f.signerKey || ''
        };
        // Bind to the nearest merge tag from the CURRENT position (so a moved
        // field re-anchors). x/y stay as the fallback at generation.
        const tagsLoaded = !!(this._tagAnchors && this._tagAnchors.length);
        const a = this.findAnchor(base.x, base.y, base.page);
        if (a) {
            base.anchorTag = a.tag; base.anchorOcc = a.occ; base.anchorPage = a.page;
            base.anchorDx = a.dx; base.anchorDy = a.dy;
        } else if (!tagsLoaded && f.anchorTag) {
            // The preview hasn't been analysed yet, so we cannot recompute — keep
            // what was stored rather than dropping the anchor on an unrelated save.
            base.anchorTag = f.anchorTag; base.anchorOcc = f.anchorOcc;
            base.anchorPage = f.anchorPage;
            base.anchorDx = f.anchorDx; base.anchorDy = f.anchorDy;
        }
        // Tags loaded but nothing qualified: the field is deliberately left
        // unanchored and keeps its absolute position. Carrying a stale anchor
        // forward here is what let a rejected cross-page anchor survive a re-save.
        return base;
    }

    hydrateFields() {
        // Only hydrate from initialFields once (subsequent edits live in
        // this.fields and are emitted upward; we don't want to clobber them).
        if (this._fieldsHydrated) return;
        const src = this._initialFields || [];
        if (!src.length && !this._templateFileId) {
            // Defer until we at least have inputs; connectedCallback re-calls.
            return;
        }
        this.fields = src.map((p, i) => this.mapFromPlacement(p, i));
        this._fieldsHydrated = true;
    }

    /**
     * Fields placed on the document that no signer owns.
     *
     * These are easy to create by accident — dropping a field before picking a
     * signer, or removing a signer that fields were pointing at — and the cost is
     * hidden: at generation an unassigned placement has nobody to fill it, so it is
     * skipped and simply never appears on the agreement. Surfacing the count here
     * turns that silent loss into something the author can see and fix.
     *
     * A key that no longer matches any signer counts as unassigned too, which is
     * exactly what signerMetaForKey already reports on the field's own tag.
     */
    get unassignedFields() {
        return (this.fields || []).filter(
            f => this.signerMetaForKey(f.signerKey).name === 'Unassigned'
        );
    }

    get unassignedCount() { return this.unassignedFields.length; }
    get hasUnassignedFields() { return this.unassignedCount > 0; }

    get unassignedMessage() {
        const n = this.unassignedCount;
        return n === 1
            ? '1 field is not assigned to a signer'
            : `${n} fields are not assigned to a signer`;
    }

    /** The unassigned fields, labelled for the warning list. */
    get unassignedList() {
        return this.unassignedFields.map(f => ({
            id: f.id,
            label: (f.fieldType || 'Field') + ' - page ' + (f.pageNumber || 1)
        }));
    }

    // Resolve a signer key to a display name + stable color.
    signerMetaForKey(key) {
        if (!key) return { name: 'Unassigned', color: '#94a3b8' };
        const idx = this._signerOptions.findIndex(o => o.value === key);
        if (idx === -1) return { name: 'Unassigned', color: '#94a3b8' };
        return {
            name: this._signerOptions[idx].label,
            color: SIGNER_COLORS[idx % SIGNER_COLORS.length]
        };
    }

    // Re-derive signerName/signerColor on every field when the signer list
    // changes (rename / reorder on the Signers tab).
    refreshSignerMeta() {
        if (!this.fields || !this.fields.length) return;
        this.fields = this.fields.map(f => {
            const meta = this.signerMetaForKey(f.signerKey);
            return { ...f, signerName: meta.name, signerColor: meta.color };
        });
    }

    /* ── Emit changes upward ── */

    emitChange() {
        const placements = this.fields.map(f => this.toPlacement(f));
        this.dispatchEvent(new CustomEvent('fieldschange', {
            detail: { fields: placements }
        }));
    }

    /* ── Drag from Palette ── */

    handleDragStart(e) {
        const type = e.currentTarget.dataset.type;
        this._dragFieldType = type;
        e.dataTransfer.setData('text/plain', type);
        e.dataTransfer.effectAllowed = 'copy';

        const size = DEFAULT_SIZES[type] || { w: 150, h: 40 };
        const ftDef = FIELD_TYPES.find(t => t.type === type);
        const ghostKey = ftDef ? ftDef.typeKey : 'text';
        const label = ftDef ? ftDef.label : type;
        const meta = this.signerMetaForKey(this.selectedSignerKey);
        const color = meta.color;
        const signerName = meta.name;
        const tint = `color-mix(in srgb, ${color} 9%, #ffffff)`;
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
        boxIcon.appendChild(fieldIconNode(ghostKey, color, px(13)));
        const boxLabel = document.createElement('span');
        boxLabel.style.cssText =
            `font-size:${px(11)}px;font-weight:600;color:${color};letter-spacing:0.1px;`;
        boxLabel.textContent = label;
        box.appendChild(boxIcon);
        box.appendChild(boxLabel);

        ghost.appendChild(chip);
        ghost.appendChild(box);
        document.body.appendChild(ghost);
        e.dataTransfer.setDragImage(ghost, bw / 2, chipH + chipGap + bh / 2);
        this._dragGhost = ghost;
        setTimeout(() => this.removeGhost(), 0);
    }

    handleDragEnd() {
        this._dragFieldType = null;
        this.isDragOver = false;
        this.removeGhost();
    }

    handleDragOver(e) {
        e.preventDefault();
        e.dataTransfer.dropEffect = 'copy';
        this.isDragOver = true;
    }

    handleDragLeave(e) {
        const rect = e.currentTarget.getBoundingClientRect();
        if (e.clientX < rect.left || e.clientX > rect.right ||
            e.clientY < rect.top || e.clientY > rect.bottom) {
            this.isDragOver = false;
        }
    }

    handleDrop(e) {
        e.preventDefault();
        e.stopPropagation();
        this.isDragOver = false;

        const fieldType = e.dataTransfer.getData('text/plain');
        this.placeFieldAtPoint(fieldType, e.clientX, e.clientY);
        this._dragFieldType = null;
    }

    /**
     * Place a new field at a viewport point. Shared by native HTML5 drop (desktop
     * mouse) and the pointer/touch drag path (mobile/tablet), so both land fields
     * identically. No-ops when the point is outside the canvas.
     */
    placeFieldAtPoint(fieldType, clientX, clientY) {
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

        // The drop zone is CSS-scaled by zoom (transform: scale). Page positions
        // (pp.top/left) are in the UNSCALED space, so divide the displayed drop
        // point by the zoom factor — otherwise the error grows with page number.
        const z = (this.zoom || 100) / 100;
        const absX = (clientX - wrapperRect.left + scrollLeft) / z;
        const absY = (clientY - wrapperRect.top + scrollTop) / z;

        const pageNum = this.getPageFromY(absY);
        const pageInfo = this.pagePositions.find(p => p.page === pageNum);
        if (!pageInfo) return; // wait for document to finish loading

        const size = DEFAULT_SIZES[fieldType];

        // Normalize the drop point (current render px) back to REFERENCE_PAGE_WIDTH.
        const scale = REFERENCE_PAGE_WIDTH / Number(pageInfo.width);
        let xPos = (absX - pageInfo.left) * scale - size.w / 2;
        let yPos = (absY - pageInfo.top) * scale - size.h / 2;

        xPos = Math.max(0, Math.min(xPos, REFERENCE_PAGE_WIDTH - size.w));
        yPos = Math.max(0, yPos);

        this.addField(fieldType, xPos, yPos, pageNum);
    }

    // ── Pointer/touch drag from the palette (mobile & tablet) ──
    // Native HTML5 drag doesn't fire on touch, so touch/pen pointers get a manual
    // drag with a floating ghost. Desktop mouse keeps the native path untouched.

    handlePalettePointerDown(e) {
        if (e.pointerType === 'mouse') return; // desktop uses native HTML5 drag
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
        e.preventDefault(); // stop the page from scrolling while dragging

        if (this._touchGhost) {
            this._touchGhost.style.left = `${e.clientX}px`;
            this._touchGhost.style.top = `${e.clientY}px`;
        }

        const wrapper = this.template.querySelector('.sf-canvas-scroll');
        if (wrapper) {
            const r = wrapper.getBoundingClientRect();
            this.isDragOver =
                e.clientX >= r.left && e.clientX <= r.right &&
                e.clientY >= r.top && e.clientY <= r.bottom;
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

        // pointercancel has no useful coordinates — only place on a real pointerup.
        if (e.type === 'pointerup') {
            this.placeFieldAtPoint(type, e.clientX, e.clientY);
        }
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
            'background:#fff;border:1px solid #7c3aed;color:#4f46e5;font-weight:600;font-size:13px;' +
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

    removeGhost() {
        if (this._dragGhost && this._dragGhost.parentNode) {
            this._dragGhost.parentNode.removeChild(this._dragGhost);
        }
        this._dragGhost = null;
    }

    /* ── Drag to Reposition ── */

    handleFieldPointerDown(e) {
        if (e.target.closest('.sf-field-del')) return;

        const fieldId = e.currentTarget.dataset.id;
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

    handleFieldPointerUp() {
        if (!this._draggingId) return;

        document.removeEventListener('pointermove', this._pointerMoveHandler);
        document.removeEventListener('pointerup', this._pointerUpHandler);

        const fieldEls = this.template.querySelectorAll('.sf-field-overlay');
        fieldEls.forEach(el => { el.style.opacity = ''; el.style.zIndex = ''; });

        this._draggingId = null;
        // Persist the new position up to the parent layout.
        this.emitChange();
    }

    /* ── Field Creation ── */

    addField(fieldType, xPos, yPos, pageNum) {
        const size = DEFAULT_SIZES[fieldType] || { w: 150, h: 40 };
        const meta = this.signerMetaForKey(this.selectedSignerKey);

        const newField = {
            id: `tf-new-${this._localIdSeq++}`,
            fieldType,
            fieldLabel: fieldType,
            pageNumber: pageNum,
            xPos,
            yPos,
            width: size.w,
            height: size.h,
            pageWidth: REFERENCE_PAGE_WIDTH,
            isRequired: true,
            signerKey: this.selectedSignerKey || '',
            signerName: meta.name,
            signerColor: meta.color
        };

        this.fields = [...this.fields, newField];
        this.selectedFieldId = newField.id;
        this.emitChange();

        // With one signer there is nothing to ask: assign it and move on. With
        // several, the field has landed but has nobody to fill it, so ask now
        // rather than let it sit in the "unassigned" warning at the end.
        if (!newField.signerKey && this._signerOptions.length > 1) {
            this._pendingAssignId = newField.id;
            this.showAssignPrompt = true;
        }
    }

    /* ── "Who is this field for?" prompt ── */

    /**
     * Only fires when there is a real choice to make. One signer auto-assigns in
     * the signerOptions setter; zero signers leaves the field unassigned, which
     * the existing warning already covers.
     */
    get assignPromptOptions() {
        return this._signerOptions.map((o, i) => ({
            value: o.value,
            label: o.label,
            color: SIGNER_COLORS[i % SIGNER_COLORS.length],
            style: `background:${SIGNER_COLORS[i % SIGNER_COLORS.length]}`
        }));
    }

    handleAssignPromptPick(e) {
        const key = e.currentTarget.dataset.key;
        const id = this._pendingAssignId;
        this.closeAssignPrompt();
        if (!key || !id) return;

        const meta = this.signerMetaForKey(key);
        this.fields = this.fields.map(f =>
            f.id === id
                ? { ...f, signerKey: key, signerName: meta.name, signerColor: meta.color }
                : f
        );
        // Becomes the default for the next drop, so placing ten fields for the
        // same person asks once rather than ten times. Changed any time from the
        // Assign To picker in Properties.
        this.selectedSignerKey = key;
        this.emitChange();
    }

    closeAssignPrompt() {
        this.showAssignPrompt = false;
        this._pendingAssignId = null;
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

    handleDeleteField(e) {
        e.stopPropagation();
        const id = e.currentTarget.dataset.id;
        this.fields = this.fields.filter(f => f.id !== id);
        if (this.selectedFieldId === id) this.selectedFieldId = null;
        this.emitChange();
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
        this.emitChange();
    }

    handleFieldSignerChange(e) {
        const signerKey = e.target.value;
        const meta = this.signerMetaForKey(signerKey);
        this.fields = this.fields.map(f =>
            f.id === this.selectedFieldId ? {
                ...f,
                signerKey,
                signerName: meta.name,
                signerColor: meta.color
            } : f
        );
        this.emitChange();
    }

    handleFieldWidthChange(e) {
        const inputPx = parseFloat(e.target.value);
        if (!inputPx || inputPx < 1) return;
        const field = this.fields.find(f => f.id === this.selectedFieldId);
        if (!field) return;

        const scale = this.getPageScale(field.pageNumber);
        let refWidth = inputPx / scale;
        const maxAllowed = Math.max(10, REFERENCE_PAGE_WIDTH - Number(field.xPos));
        refWidth = Math.max(10, Math.min(refWidth, maxAllowed));

        this.fields = this.fields.map(f =>
            f.id === this.selectedFieldId ? { ...f, width: refWidth } : f
        );
        this.emitChange();
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
        this.emitChange();
    }

    handleFieldRequiredChange(e) {
        const newRequired = e.target.checked;
        const fieldId = this.selectedFieldId;
        this.fields = this.fields.map(f =>
            f.id === fieldId ? { ...f, isRequired: newRequired } : f
        );
        this.emitChange();
    }

    handleSignerChange(e) {
        this.selectedSignerKey = e.target.value;
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

    handleCanvasClick() {
        if (!this._draggingId) {
            this.selectedFieldId = null;
        }
    }
}
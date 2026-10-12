import { LightningElement, track, wire } from 'lwc';
import USER_ID from '@salesforce/user/Id';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { stripNs, vfPageUrl } from 'c/nsUtils';
import listTemplates from '@salesforce/apex/TemplateService.listTemplates';
import getTemplate from '@salesforce/apex/TemplateService.getTemplate';
import getEligibleObjects from '@salesforce/apex/TemplateService.getEligibleObjects';
import registerTemplate from '@salesforce/apex/TemplateService.registerTemplate';
import deleteTemplate from '@salesforce/apex/TemplateService.deleteTemplate';
import getContentVersionId from '@salesforce/apex/TemplateService.getContentVersionId';
import getTemplateParseState from '@salesforce/apex/TemplateService.getTemplateParseState';
import validateTemplateTags from '@salesforce/apex/TemplateService.validateTemplateTags';
import getObjectFieldTree from '@salesforce/apex/TemplateService.getObjectFieldTree';
import getRelatedObjectFields from '@salesforce/apex/TemplateService.getRelatedObjectFields';
import getTemplateLayout from '@salesforce/apex/TemplateService.getTemplateLayout';
import saveTemplateLayout from '@salesforce/apex/TemplateService.saveTemplateLayout';
import getTemplatePreviewUrl from '@salesforce/apex/TemplateService.getTemplatePreviewUrl';
import getStoredTemplatePreviewCvId from '@salesforce/apex/TemplateService.getStoredTemplatePreviewCvId';
import getSampleMergedPreviewCvId from '@salesforce/apex/DocumentGenerationService.getSampleMergedPreviewCvId';

// Upper bound for the "number of signers" box. Not a platform limit — it is a
// guard so a typo like 500 cannot render five hundred rows and hang the tab.
const SIGNER_COUNT_MAX = 10;


const EMPTY_FORM = {
    id: null,
    name: '',
    objectApiName: '',
    description: '',
    outputFormat: 'DOCX',
    outputFilenamePattern: '',
    active: true,
    autoCreateAgreement: false,
    defaultAgreementType: 'Other',
    templateFileId: null,
    contentDocumentId: null,
    lastParsedDate: null,
    lastParseError: null
};

const FORMAT_OPTIONS = [
    { label: 'DOCX', value: 'DOCX' },
    { label: 'PDF', value: 'PDF' }
];

const AGREEMENT_TYPE_OPTIONS = [
    { label: 'NDA', value: 'NDA' },
    { label: 'Contract', value: 'Contract' },
    { label: 'Proposal', value: 'Proposal' },
    { label: 'Invoice', value: 'Invoice' },
    { label: 'HR Document', value: 'HR Document' },
    { label: 'Other', value: 'Other' }
];

const TYPE_BADGE_MAP = {
    STRING: { label: 'TEXT', cls: 'tag-string' },
    TEXTAREA: { label: 'TEXT', cls: 'tag-string' },
    PICKLIST: { label: 'PICK', cls: 'tag-picklist' },
    MULTIPICKLIST: { label: 'PICK', cls: 'tag-picklist' },
    EMAIL: { label: 'EMAIL', cls: 'tag-email' },
    PHONE: { label: 'PHONE', cls: 'tag-phone' },
    URL: { label: 'URL', cls: 'tag-url' },
    BOOLEAN: { label: 'BOOL', cls: 'tag-bool' },
    DATE: { label: 'DATE', cls: 'tag-date' },
    DATETIME: { label: 'DATETIME', cls: 'tag-date' },
    TIME: { label: 'TIME', cls: 'tag-date' },
    CURRENCY: { label: 'CURRENCY', cls: 'tag-currency' },
    DOUBLE: { label: 'NUMBER', cls: 'tag-number' },
    INTEGER: { label: 'NUMBER', cls: 'tag-number' },
    PERCENT: { label: 'PERCENT', cls: 'tag-number' },
    REFERENCE: { label: 'REF', cls: 'tag-rel' },
    ID: { label: 'ID', cls: 'tag-id' },
    ADDRESS: { label: 'ADDR', cls: 'tag-string' }
};

/* Describe type names, said the way a non-technical author would. Shown beside
   each detected tag on the Tags tab; TYPE_BADGE_MAP above is the terser variant
   used in the field-reference panel's badges. */
const TYPE_LABELS = {
    STRING: 'Text',        TEXTAREA: 'Text',       PICKLIST: 'Picklist',
    MULTIPICKLIST: 'Picklist', EMAIL: 'Email',     PHONE: 'Phone',
    URL: 'URL',            BOOLEAN: 'Checkbox',    DATE: 'Date',
    DATETIME: 'Date & time', TIME: 'Time',         CURRENCY: 'Currency',
    DOUBLE: 'Number',      INTEGER: 'Number',      LONG: 'Number',
    PERCENT: 'Percent',    REFERENCE: 'Lookup',    ID: 'Id',
    ADDRESS: 'Address',    LIST: 'Related list',   TEXT: 'Text'
};

const TAB_SETUP = 'setup';
const TAB_TEMPLATE = 'template';
const TAB_TAGS = 'tags';
const TAB_SIGNERS = 'signers';
const TAB_FIELDS = 'fields';

// Mirror createAgreement / signermanager roleOptions so template-level signers
// use the exact same Role__c values that get materialized into Signer__c rows.
const SIGNER_ROLE_OPTIONS = [
    { label: 'Signer', value: 'Signer' },
    { label: 'CC Only', value: 'CC' }
];

// Same email shape used in createAgreement & signermanager — keep consistent.
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export default class TemplateLibrary extends LightningElement {
    @track templates = [];
    @track isLoading = true;
    @track dialogOpen = false;
    @track form = { ...EMPTY_FORM };
    @track parsedFields = [];
    @track isParsing = false;
    @track isSaving = false;
    @track objectOptions = [];

    // Field reference panel state
    @track fieldTree = null;
    @track isLoadingFieldTree = false;
    @track fieldSearch = '';

    // "Browse related object" dropdown state — pick a parent relationship or a
    // child collection to see ALL its fields (the inline sections stay capped).
    @track selectedRelatedKey = '';
    @track relatedFields = [];
    @track relatedObjectLabel = '';
    @track relatedLoopHint = '';
    @track relatedLoading = false;
    @track relatedPickerSearch = '';
    @track relatedDropdownOpen = false;

    // Tab state
    @track activeTab = TAB_SETUP;

    // Tag-parse state, driven by the upload. The Signers and Fields tabs are built
    // from the parsed merge tags, so they stay closed until this reports ready.
    @track tagsReady = false;
    @track parseError = null;
    @track parsedTagCount = 0;
    _parseToken = null;

    @track showPreviewSection = false;
    @track previewLoading = false;
    @track previewUrl = '';

    // The ContentVersion the Fields-tab editor renders. Resolves to the
    // pre-built, Salesforce-stored PDF preview (instant — no Lambda) when
    // available, else the raw DOCX (on-demand conversion, first time only).
    @track fieldsPreviewFileId = null;
    _fieldsPreviewSource = null;   // the DOCX id fieldsPreviewFileId was resolved for
    // Sample-data preview: place fields on the template MERGED with a real record,
    // so the placement surface matches the generated agreement (much less drift).
    @track sampleRecordId = null;
    @track sampleLoading = false;
    _savedTemplateFileId = null;   // DOCX id persisted on the template (stored PDF is valid only for this)

    // ── Signers & Fields tab state ──
    // signerRows: template-level signers being edited. Each row carries a stable
    // `key` (used later for field-assignment mapping in the drag-drop slice).
    @track signerRows = [];
    // Preserve any existing "fields" array from the stored layout so saving the
    // signers slice never drops the (reserved) field-placement data.
    _layoutFields = [];
    // Monotonic counter so every added signer row gets a unique stable key.
    _signerKeySeq = 0;

    formatOptions = FORMAT_OPTIONS;
    agreementTypeOptions = AGREEMENT_TYPE_OPTIONS;
    signerRoleOptions = SIGNER_ROLE_OPTIONS;

    _wiredTemplates;
    _fieldTreeCache = {};

    @wire(listTemplates)
    wiredList(result) {
        this._wiredTemplates = result;
        if (result.data) {
            this.templates = result.data.map(raw => {
                const t = stripNs(raw);
                return {
                    ...t,
                    fieldCount: t.Template_Fields__r ? t.Template_Fields__r.length : 0
                };
            });
            // A shrunk list (e.g. after delete) must not leave the page out of range.
            if (this.currentPage > this.totalPages) this.currentPage = 1;
            this.isLoading = false;
        } else if (result.error) {
            console.error('listTemplates failed', result.error);
            this.isLoading = false;
            this.toast('Error', 'Could not load templates', 'error');
        }
    }

    @wire(getEligibleObjects)
    wiredObjects({ data, error }) {
        if (data) {
            this.objectOptions = data.map(o => ({ label: o.label, value: o.value }));
        } else if (error) {
            console.error('getEligibleObjects failed', error);
        }
    }

    /* ── Tab computed state ── */
    get isSetupTab() { return this.activeTab === TAB_SETUP; }
    get isTemplateTab() { return this.activeTab === TAB_TEMPLATE; }
    get isTagsTab() { return this.activeTab === TAB_TAGS; }
    get isSignersTab() { return this.activeTab === TAB_SIGNERS; }
    get isFieldsTab() { return this.activeTab === TAB_FIELDS; }

    get tabSetupClass() { return this.isSetupTab ? 'tab-button tab-active' : 'tab-button'; }
    get tabTemplateClass() { return this.isTemplateTab ? 'tab-button tab-active' : 'tab-button'; }
    get tabTagsClass() { return this.isTagsTab ? 'tab-button tab-active' : 'tab-button'; }
    get tabSignersClass() {
        const base = this.isSignersTab ? 'tab-button tab-active' : 'tab-button';
        return this.tagStepsLocked ? base + ' tab-disabled' : base;
    }
    get tabFieldsClass() {
        const base = this.isFieldsTab ? 'tab-button tab-active' : 'tab-button';
        return this.tagStepsLocked ? base + ' tab-disabled' : base;
    }

    /**
     * Signers and Fields are unusable until the uploaded document has been read:
     * both are built from its merge tags, and the Fields editor anchors placements
     * to them. A template that already parsed (re-opened for editing) is fine.
     */
    get tagStepsLocked() {
        if (this.isParsing) return true;
        if (!this.form.templateFileId) return false;   // no document yet — nothing to wait for
        if (this.tagsReady) return false;
        return !this.form.lastParsedDate;              // parsed in an earlier session
    }

    get tagStepsDisabled() { return this.tagStepsLocked; }

    get hasSignerRows() { return this.signerRows && this.signerRows.length > 0; }

    /* Signer options for the Fields-tab editor's Assign-To dropdown, keyed by the
       stable signer `key` so placements map back to a signer at materialization. */
    get signerFieldOptions() {
        return this.signerRows
            .filter(r => r.role !== 'CC')
            .map(r => ({
                label: r.name || r.email || ('Signer ' + r.order),
                value: r.key
            }));
    }

    /* The merge-tag reference pane belongs to the Template tab, where the author
       is assembling a DOCX and needs tags to paste into it. It used to show on
       the Tags tab too, but that tab already lists every tag the document
       actually contains — and now says what each one resolves to — so the
       reference there was duplicated content costing 380px of width. */
    get showFieldsPane() {
        return this.isTemplateTab;
    }

    /* Left pane class adjusts based on whether the right fields pane is showing.
       When Setup tab is active, the form takes the full width.
       The Fields tab additionally locks the pane's own scrollbar: the editor
       fills the remaining height and scrolls its document canvas internally, so
       the modal itself never scrolls. */
    get leftPaneClass() {
        const base = this.showFieldsPane ? 'modal-form-pane' : 'modal-form-pane modal-form-pane-full';
        return this.isFieldsTab ? base + ' modal-form-pane-fields' : base;
    }

    /* The Template tab shows the two panes reversed: the merge-tag reference on
       the left, the upload form on the right. It is done with a class that flips
       the grid's column widths and `order`, NOT by moving the panes in the DOM —
       reordering the markup would tear down and rebuild the uploader every time
       the tab changed, losing a file picked but not yet parsed. */
    get bodyTabsClass() {
        return this.isTemplateTab
            ? 'modal-body-tabs modal-body-tabs-swapped'
            : 'modal-body-tabs';
    }

    /* ── Other computed ── */
    get hasTemplates() { return this.templates && this.templates.length > 0; }

    // ── Grid pagination (server orders by CreatedDate DESC) ──
    @track currentPage = 1;
    // Two grid rows per page. The grid is auto-fill so the column count depends
    // on viewport width — recomputed from the rendered grid, so the pager only
    // appears when the list genuinely overflows two rows.
    @track pageSize = 6;

    renderedCallback() {
        this._syncPageSize();
        if (!this._onResize) {
            this._onResize = () => this._syncPageSize();
            window.addEventListener('resize', this._onResize);
        }
    }

    disconnectedCallback() {
        if (this._onResize) {
            window.removeEventListener('resize', this._onResize);
            this._onResize = null;
        }
    }

    _syncPageSize() {
        const grid = this.template.querySelector('.template-grid');
        if (!grid) return;
        const cols = getComputedStyle(grid).gridTemplateColumns.split(' ').filter(Boolean).length;
        const size = Math.max(1, cols) * 2;
        if (size !== this.pageSize) {
            this.pageSize = size;
            if (this.currentPage > this.totalPages) this.currentPage = this.totalPages;
        }
    }

    get totalPages() { return Math.max(1, Math.ceil((this.templates ? this.templates.length : 0) / this.pageSize)); }
    get pagedTemplates() {
        const start = (this.currentPage - 1) * this.pageSize;
        return (this.templates || []).slice(start, start + this.pageSize);
    }
    get showPagination() { return this.totalPages > 1; }
    get disablePrev() { return this.currentPage <= 1; }
    get disableNext() { return this.currentPage >= this.totalPages; }
    prevPage() { if (this.currentPage > 1) this.currentPage -= 1; }
    nextPage() { if (this.currentPage < this.totalPages) this.currentPage += 1; }
    get hasParsedFields() { return this.parsedFields && this.parsedFields.length > 0; }
    get brokenTagCount() { return this.parsedFields.filter(f => f.isBroken).length; }
    get hasBrokenTags() { return this.brokenTagCount > 0; }
    get brokenTagSummary() {
        const n = this.brokenTagCount;
        return n === 1 ? '1 tag will not fill in' : `${n} tags will not fill in`;
    }
    get isExisting() { return !!this.form.id; }
    get uploadRecordId() { return this.form.id || USER_ID; }
    get dialogTitle() { return this.isExisting ? 'Edit Template' : 'New Template'; }
    get saveDisabled() { return this.isSaving || this.isParsing || !this.form.name || !this.form.objectApiName; }

    get fieldTreeLabel() {
        if (!this.fieldTree) return 'Field Reference';
        return this.fieldTree.objectLabel + ' Fields';
    }

    get visibleBuiltins() {
        const t = this.fieldTree;
        if (!t || !t.builtins) return [];
        const list = t.builtins;
        if (!this.fieldSearch) return list;
        return this._filterList(list);
    }

    get visibleFields() {
        const t = this.fieldTree;
        if (!t || !t.fields) return [];
        return this._enrichFields(this._maybeFilter(t.fields));
    }

    get visibleRelationships() {
        const t = this.fieldTree;
        if (!t || !t.relationships) return [];
        if (!this.fieldSearch) return t.relationships;
        const q = this.fieldSearch.toLowerCase();
        return t.relationships
            .map(rel => ({
                ...rel,
                fields: rel.fields.filter(f =>
                    (f.label && f.label.toLowerCase().includes(q)) ||
                    (f.tag && f.tag.toLowerCase().includes(q)) ||
                    (rel.label && rel.label.toLowerCase().includes(q))
                )
            }))
            .filter(rel => rel.fields.length > 0);
    }

    get visibleChildCollections() {
        const t = this.fieldTree;
        if (!t || !t.childCollections) return [];
        if (!this.fieldSearch) return t.childCollections;
        const q = this.fieldSearch.toLowerCase();
        return t.childCollections.filter(cc =>
            (cc.label && cc.label.toLowerCase().includes(q)) ||
            (cc.name && cc.name.toLowerCase().includes(q))
        );
    }

    get hasVisibleFields() { return this.visibleFields && this.visibleFields.length > 0; }
    get hasVisibleRelationships() { return this.visibleRelationships && this.visibleRelationships.length > 0; }
    get hasVisibleChildren() { return this.visibleChildCollections && this.visibleChildCollections.length > 0; }

    get noMatches() {
        // Default view shows only the main object's own fields, so the
        // "no matches" notice keys off that list alone.
        return this.fieldSearch && this.visibleFields.length === 0;
    }

    _maybeFilter(list) {
        if (!this.fieldSearch) return list;
        return this._filterList(list);
    }

    _filterList(list) {
        const q = this.fieldSearch.toLowerCase();
        return list.filter(f =>
            (f.label && f.label.toLowerCase().includes(q)) ||
            (f.tag && f.tag.toLowerCase().includes(q)) ||
            (f.name && f.name.toLowerCase().includes(q))
        );
    }

    _enrichFields(list) {
        return list.map(f => {
            const meta = TYPE_BADGE_MAP[f.type] || { label: 'FIELD', cls: 'tag-field' };
            return {
                ...f,
                typeShort: meta.label,
                typeBadgeClass: 'tag-badge ' + meta.cls
            };
        });
    }

    /* ── Tab handler ── */
    handleTabClick(e) {
        const tab = e.currentTarget.dataset.tab;
        if (!tab) return;
        if ((tab === TAB_SIGNERS || tab === TAB_FIELDS) && this.tagStepsLocked) {
            this.toast(
                this.isParsing ? 'Reading your template' : 'Upload a template first',
                this.isParsing
                    ? 'Merge tags are still being detected. This opens as soon as they are ready.'
                    : 'Signers and Fields are built from the template\'s merge tags. Upload a DOCX on the Template tab.',
                'warning'
            );
            return;
        }
        this.activeTab = tab;
        // Resolve the fast preview id lazily when the Fields tab is opened
        // (a no-op if _loadTemplateIntoForm already pre-warmed it).
        if (tab === TAB_FIELDS) this.resolveFieldsPreviewFileId();
    }

    /* Point the Fields editor at the Salesforce-stored PDF preview so it renders
       without a per-open Lambda DOCX→PDF round-trip. Falls back to the raw DOCX
       when the cache isn't built yet (a just-uploaded template) - that one open
       converts on demand and the stored copy is built for next time. */
    async resolveFieldsPreviewFileId() {
        const docx = this.form.templateFileId || null;
        if (!docx) { this.fieldsPreviewFileId = null; this._fieldsPreviewSource = null; return; }

        // Sample-data preview wins when a record is chosen: render the template
        // MERGED with that record so the placement surface matches the generated
        // agreement. Requires a saved template (needs an Id to merge against).
        if (this.sampleRecordId && this.form.id) {
            const srcKey = 'sample:' + this.sampleRecordId;
            if (this._fieldsPreviewSource === srcKey && this.fieldsPreviewFileId) return;
            this._fieldsPreviewSource = srcKey;
            this.fieldsPreviewFileId = null;   // preparing-spinner while we build it
            this.sampleLoading = true;
            try {
                const cvId = await getSampleMergedPreviewCvId({
                    templateId: this.form.id, sampleRecordId: this.sampleRecordId
                });
                if (this._fieldsPreviewSource !== srcKey) return;  // changed mid-flight
                if (cvId) { this.fieldsPreviewFileId = cvId; return; }
            } catch (e) {
                this.toast('Sample preview failed',
                    e.body?.message || 'Could not build the sample preview.', 'error');
            } finally {
                this.sampleLoading = false;
            }
            // sample failed → fall through to the placeholder preview below
        }

        // Already resolved for this exact source — don't churn the editor.
        if (this._fieldsPreviewSource === docx && this.fieldsPreviewFileId) return;
        this._fieldsPreviewSource = docx;
        // The stored PDF is keyed by template, not by file version — only trust it
        // when the current file IS the saved one. After an unsaved re-upload we must
        // convert the new DOCX on demand, or the editor would show the old document.
        const canUseStored = this.form.id && docx === this._savedTemplateFileId;
        if (canUseStored) {
            try {
                const storedCvId = await getStoredTemplatePreviewCvId({ templateId: this.form.id });
                if (this._fieldsPreviewSource !== docx) return;  // source changed mid-flight
                if (storedCvId) { this.fieldsPreviewFileId = storedCvId; return; }
            } catch (e) { /* fall through to the DOCX */ }
        }
        if (this._fieldsPreviewSource === docx) this.fieldsPreviewFileId = docx;
    }

    /* Sample-record picker on the Fields tab: choosing a record re-renders the
       preview merged with that record's real data; clearing goes back to the
       raw {{merge-tag}} template. */
    handleSampleRecordChange(e) {
        const recId = e && e.detail ? e.detail.recordId : null;
        this.sampleRecordId = recId || null;
        this.resolveFieldsPreviewFileId();
    }
    handleClearSample() {
        if (!this.sampleRecordId) return;
        this.sampleRecordId = null;
        // Force a re-resolve back to the placeholder/stored preview.
        this._fieldsPreviewSource = null;
        this.fieldsPreviewFileId = null;
        this.resolveFieldsPreviewFileId();
    }
    get hasSampleRecord() { return !!this.sampleRecordId; }
    get previewLoadingText() {
        return this.sampleLoading ? 'Building sample preview…' : 'Preparing preview…';
    }

    /* ── Signers & Fields tab: template-level signer editor ──
       Each row mirrors the createAgreement signer shape (name/email/role/order)
       plus a stable `key` reserved for field-assignment mapping in a later slice.
       The list is held in component state and serialized to
       Document_Template__c.Template_Layout_JSON__c on save. */

    _newSignerKey() {
        this._signerKeySeq += 1;
        return 's' + this._signerKeySeq;
    }

    // Build the signerRows view from a parsed layout's signers[] (defaults []).
    _hydrateSignersFromLayout(layout) {
        this._signerKeySeq = 0;
        this._layoutFields = (layout && Array.isArray(layout.fields)) ? layout.fields : [];
        const signers = (layout && Array.isArray(layout.signers)) ? layout.signers : [];
        this.signerRows = signers.map((s, idx) => ({
            key: (s && s.key) ? s.key : this._newSignerKey(),
            name: (s && s.name) || '',
            email: (s && s.email) || '',
            role: (s && s.role) || 'Signer',
            order: (s && (s.order || s.order === 0)) ? s.order : idx + 1
        }));
        // Keep the key sequence ahead of any pre-existing 'sN' keys so new rows
        // never collide with loaded ones.
        this.signerRows.forEach(r => {
            const m = /^s(\d+)$/.exec(r.key || '');
            if (m) {
                const n = parseInt(m[1], 10);
                if (n > this._signerKeySeq) this._signerKeySeq = n;
            }
        });
    }

    handleAddSignerRow() {
        this.signerRows = [
            ...this.signerRows,
            {
                key: this._newSignerKey(),
                name: '',
                email: '',
                role: 'Signer',
                order: this.signerRows.length + 1
            }
        ];
    }

    /** Drives the "how many signers" box; always mirrors the real row count. */
    get signerCount() {
        return this.signerRows.length;
    }

    /**
     * Set the number of signer rows in one go, instead of clicking Add Signer
     * once per person.
     *
     * Growing appends blanks. Shrinking removes from the end, but stops at the
     * first row that has a name or an email rather than throwing typed-in work
     * away — someone correcting 12 to 2 in a box does not expect ten filled rows
     * to vanish. Those have to go through the row's own delete button, which is
     * a deliberate act on a specific row.
     */
    handleSignerCountChange(e) {
        const raw = parseInt(e.target.value, 10);
        const current = this.signerRows.length;

        // Empty or nonsense: leave the box exactly as typed and do nothing.
        //
        // This used to write the current count back here, which broke the box in
        // two ways. Clearing it refilled instantly, so you could never type a new
        // number. And with rows that could not be removed, typing "12" got the
        // "1" replaced by the real count mid-keystroke and ended up as "22".
        // Nothing writes to the input during typing now — handleSignerCountBlur
        // reconciles it once, after focus leaves.
        if (isNaN(raw) || raw < 0) return;

        const wanted = Math.min(raw, SIGNER_COUNT_MAX);
        if (raw > SIGNER_COUNT_MAX) {
            this.toast('Too many signers',
                'You can define up to ' + SIGNER_COUNT_MAX + ' signers on a template.',
                'warning');
        }

        if (wanted > current) {
            const added = [];
            for (let i = current; i < wanted; i++) {
                added.push({
                    key: this._newSignerKey(),
                    name: '',
                    email: '',
                    role: 'Signer',
                    order: i + 1
                });
            }
            this.signerRows = [...this.signerRows, ...added];
            return;
        }

        if (wanted < current) {
            const rows = [...this.signerRows];
            let removed = 0;
            while (rows.length > wanted) {
                const last = rows[rows.length - 1];
                const hasData = (last.name || '').trim() || (last.email || '').trim();
                if (hasData) break;
                rows.pop();
                removed++;
            }
            this.signerRows = rows.map((r, idx) => ({ ...r, order: idx + 1 }));

            if (rows.length > wanted) {
                this.toast('Kept the filled rows',
                    'Removed ' + removed + ' empty row(s). The rest already have a name or '
                    + 'email, so delete those individually with the bin icon.',
                    'info');
            }
        }
    }

    /**
     * Put the box back in step with reality, once, after focus leaves.
     *
     * Doing this on every keystroke is what broke typing. On blur it is safe: the
     * number shown then matches the rows actually on screen, whether the user
     * cleared it, typed something impossible, or asked for a shrink that stopped
     * at a filled row.
     */
    handleSignerCountBlur(e) {
        const shown = parseInt(e.target.value, 10);
        const actual = this.signerRows.length;
        if (isNaN(shown) || shown !== actual) {
            e.target.value = actual;
        }
    }

    handleRemoveSignerRow(e) {
        const key = e.currentTarget.dataset.key;
        const remaining = this.signerRows.filter(r => r.key !== key);
        this.signerRows = remaining.map((r, idx) => ({
            ...r,
            order: idx + 1
        }));
    }

    handleSignerNameChange(e) {
        const key = e.currentTarget.dataset.key;
        const val = e.target.value;
        this.signerRows = this.signerRows.map(r =>
            r.key === key ? { ...r, name: val } : r
        );
    }

    handleSignerEmailChange(e) {
        const key = e.currentTarget.dataset.key;
        const val = e.target.value;
        this.signerRows = this.signerRows.map(r =>
            r.key === key ? { ...r, email: val } : r
        );
    }

    handleSignerRoleChange(e) {
        const key = e.currentTarget.dataset.key;
        const val = e.target.value;
        this.signerRows = this.signerRows.map(r =>
            r.key === key ? { ...r, role: val } : r
        );
    }

    handleSignerOrderChange(e) {
        const key = e.currentTarget.dataset.key;
        const val = parseInt(e.target.value, 10);
        this.signerRows = this.signerRows.map(r =>
            r.key === key ? { ...r, order: isNaN(val) ? r.order : val } : r
        );
    }

    /* ── Fields tab: drag-drop field placements ──
       The embedded c-template-field-editor emits its full placement list on
       every change. We store it in _layoutFields, which handleSave() already
       serializes into the layout JSON's fields[] via _buildLayout(). No Apex
       or Signature_Field__c writes happen at design time. */
    handleTemplateFieldsChange(e) {
        this._layoutFields = (e.detail && e.detail.fields) || [];
    }

    /* Returns the first signer whose email is present but malformed, else null.
       A blank email is allowed at template design time - the address is often
       only known when an agreement is generated, and createAgreement /
       signermanager still require a valid one before the signer is sent. */
    _firstInvalidSigner() {
        for (const r of this.signerRows) {
            const emailTrim = (r.email || '').trim();
            if (emailTrim && !EMAIL_RE.test(emailTrim)) return r;
        }
        return null;
    }

    /**
     * Placed fields that no signer on the Signers tab owns.
     *
     * Blank keys and keys left dangling by a deleted/renamed signer both count,
     * because materializeSignersAndFieldsMapped skips either one — the placement is
     * silently dropped and never reaches the signed document.
     */
    _unassignedLayoutFields() {
        const validKeys = new Set(
            this.signerRows.map((r, idx) => r.key || ('s' + (idx + 1)))
        );
        return (this._layoutFields || []).filter(f => {
            const key = (f && f.signerKey) ? String(f.signerKey).trim() : '';
            return !key || !validKeys.has(key);
        });
    }

    /* Build the canonical layout JSON object, preserving the reserved fields[]. */
    _buildLayout() {
        const signers = this.signerRows.map((r, idx) => ({
            key: r.key || ('s' + (idx + 1)),
            name: (r.name || '').trim(),
            email: (r.email || '').trim(),
            role: r.role || 'Signer',
            order: (r.order || r.order === 0) ? r.order : idx + 1
        }));
        return { signers, fields: this._layoutFields || [] };
    }

    /* Load the stored layout for an existing template into signer state. */
    async _loadLayout(templateId) {
        try {
            const raw = await getTemplateLayout({ templateId });
            let layout = null;
            if (raw) {
                try { layout = JSON.parse(raw); } catch (e) { layout = null; }
            }
            this._hydrateSignersFromLayout(layout);
        } catch (e) {
            // Layout is additive — never block opening the editor on a load error.
            console.warn('[SignForce] getTemplateLayout failed', e);
            this._hydrateSignersFromLayout(null);
        }
    }

    /* ── Dialog open/close ── */
    openNewDialog() {
        this.form = { ...EMPTY_FORM };
        this.parsedFields = [];
        this.fieldTree = null;
        this.fieldSearch = '';
        this.activeTab = TAB_SETUP;
        // Brand-new template has no stored layout yet — start with empty signers.
        this._hydrateSignersFromLayout(null);
        this.dialogOpen = true;
    }

    async openEditDialog(e) {
        const id = e.currentTarget.dataset.id;
        this.dialogOpen = true;
        this.isLoading = true;
        this.activeTab = TAB_SETUP;
        try {
            const result = await getTemplate({ templateId: id });
            this._loadTemplateIntoForm(result);
            this.loadFieldTree(this.form.objectApiName);
            // Load template-level signers/fields layout for the Signers tab.
            await this._loadLayout(id);
        } catch (err) {
            this.toast('Error', err.body?.message || 'Could not load template', 'error');
            this.dialogOpen = false;
        } finally {
            this.isLoading = false;
        }
    }

    _loadTemplateIntoForm(result) {
        const t = stripNs(result.template);
        this.form = {
            id: t.Id,
            name: t.Name,
            objectApiName: t.Object_API_Name__c,
            description: t.Description__c || '',
            outputFormat: t.Output_Format__c || 'DOCX',
            outputFilenamePattern: t.Output_Filename_Pattern__c || '',
            active: t.Active__c !== false,
            autoCreateAgreement: t.Auto_Create_Agreement__c === true,
            defaultAgreementType: t.Default_Agreement_Type__c || 'Other',
            templateFileId: t.Template_File_Id__c,
            contentDocumentId: result.contentDocumentId || null,
            lastParsedDate: t.Last_Parsed_Date__c
                ? new Date(t.Last_Parsed_Date__c).toLocaleString()
                : null,
            lastParseError: t.Last_Parse_Error__c || null
        };
        this.parsedFields = this._shapeParsedFields(result.fields);
        this._applyTagValidation(t.Id);
        // Warm the fast Fields-tab preview id now, so the editor is ready the
        // instant the user opens the Fields tab.
        this._savedTemplateFileId = t.Template_File_Id__c;
        this.fieldsPreviewFileId = null;
        this._fieldsPreviewSource = null;
        this.resolveFieldsPreviewFileId();
    }

    closeDialog() {
        this.dialogOpen = false;
        this.form = { ...EMPTY_FORM };
        this.parsedFields = [];
        this.fieldTree = null;
        this.fieldSearch = '';
        this.activeTab = TAB_SETUP;
        this.signerRows = [];
        this._layoutFields = [];
        this._signerKeySeq = 0;
        this._resetRelated();
        this.showPreviewSection = false;
        this.previewUrl = '';
        this.previewLoading = false;
        this.fieldsPreviewFileId = null;
        this._fieldsPreviewSource = null;
        this._savedTemplateFileId = null;
        this.sampleRecordId = null;
        this.sampleLoading = false;
    }

    // BUG-031 FIX: clicking the backdrop used to call closeDialog(), which
    // wipes the whole form (name, fields, parsed tags) with no confirmation —
    // an accidental click outside the card destroyed everything the user typed.
    // The backdrop is now inert; the modal only closes via the explicit × icon
    // or the Cancel button (both still call closeDialog). Matches signermanager.
    handleBackdropClick() { /* intentionally inert - see BUG-031 */ }
    stopPropagation(e) { e.stopPropagation(); }

    /* ── Form handlers ── */
    handleNameChange(e) { this.form = { ...this.form, name: e.target.value }; }
    handleDescriptionChange(e) { this.form = { ...this.form, description: e.target.value }; }
    handleFormatChange(e) { this.form = { ...this.form, outputFormat: e.target.value }; }
    handleFilenamePatternChange(e) { this.form = { ...this.form, outputFilenamePattern: e.target.value }; }
    handleActiveChange(e) { this.form = { ...this.form, active: e.target.checked }; }
    handleAutoCreateChange(e) { this.form = { ...this.form, autoCreateAgreement: e.target.checked }; }
    handleAgreementTypeChange(e) { this.form = { ...this.form, defaultAgreementType: e.target.value }; }

    handleObjectChange(e) {
        const newObj = e.target.value;
        this.form = { ...this.form, objectApiName: newObj };
        this.loadFieldTree(newObj);
    }

    handleFieldSearch(e) {
        this.fieldSearch = e.target.value || '';
    }

    /* ── "Browse related object" dropdown ── */
    get hasRelatedObjects() {
        const t = this.fieldTree;
        return !!(t && (((t.builtins || []).length) || ((t.relationships || []).length) || ((t.childCollections || []).length)));
    }
    get _allRelatedOptions() {
        const t = this.fieldTree;
        const opts = [];
        if (t) {
            if ((t.builtins || []).length) opts.push({ label: 'Built-in / utility tags', value: 'builtin:' });
            (t.relationships || []).forEach(r => opts.push({ label: 'Parent · ' + (r.label || r.name), value: 'rel:' + r.name }));
            (t.childCollections || []).forEach(c => opts.push({ label: 'Child loop · ' + (c.label || c.name), value: 'child:' + c.name }));
        }
        return opts;
    }
    get relatedDropdownItems() {
        const sel = this.selectedRelatedKey || '';
        const q = (this.relatedPickerSearch || '').toLowerCase().trim();
        let list = this._allRelatedOptions;
        if (q) list = list.filter(o => o.label.toLowerCase().includes(q));
        const items = [];
        if (!q) {
            items.push({ value: '', label: '- Browse a related object -',
                cssClass: 'related-combo-item' + (sel === '' ? ' is-selected' : '') });
        }
        list.forEach(o => items.push({ value: o.value, label: o.label,
            cssClass: 'related-combo-item' + (o.value === sel ? ' is-selected' : '') }));
        return items;
    }
    get hasRelatedDropdownItems() { return this.relatedDropdownItems.length > 0; }
    get relatedTriggerLabel() {
        if (!this.selectedRelatedKey) return 'Browse related object… (all fields)';
        const m = this._allRelatedOptions.find(o => o.value === this.selectedRelatedKey);
        return m ? m.label : 'Browse related object…';
    }
    get isRelatedSelected() { return !!this.selectedRelatedKey; }
    get visibleRelatedFields() {
        return this.fieldSearch ? this._filterList(this.relatedFields) : this.relatedFields;
    }
    get hasVisibleRelatedFields() { return this.visibleRelatedFields.length > 0; }

    handleRelatedPickerSearch(e) {
        this.relatedPickerSearch = e.target.value || '';
    }

    toggleRelatedDropdown() {
        this.relatedDropdownOpen = !this.relatedDropdownOpen;
        if (this.relatedDropdownOpen) {
            this.relatedPickerSearch = '';
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            Promise.resolve().then(() => {
                const el = this.template.querySelector('.related-search-input');
                if (el) el.focus();
            });
        }
    }

    closeRelatedDropdown() {
        this.relatedDropdownOpen = false;
    }

    handleRelatedOptionClick(e) {
        const val = e.currentTarget.dataset.value || '';
        this.relatedDropdownOpen = false;
        this._selectRelated(val);
    }

    async _selectRelated(val) {
        this.selectedRelatedKey = val;
        this.relatedFields = [];
        this.relatedObjectLabel = '';
        this.relatedLoopHint = '';
        if (!val) return;
        const t = this.fieldTree;
        if (!t) return;

        // Built-in / utility tags (TODAY, NOW, USER.*, ORG.*) — no async load needed
        if (val === 'builtin:') {
            this.relatedFields = (t.builtins || []).map(b => ({
                name: b.name, label: b.label, tag: b.tag,
                typeShort: 'BUILTIN', typeBadgeClass: 'tag-badge tag-builtin'
            }));
            this.relatedObjectLabel = 'Built-in / utility tags';
            return;
        }

        let obj = null, prefix = '', label = '', loopName = null;
        if (val.startsWith('rel:')) {
            const name = val.slice(4);
            const r = (t.relationships || []).find(x => x.name === name);
            if (!r) return;
            obj = r.referenceTo; prefix = name + '.'; label = (r.label || name) + ' (' + r.referenceTo + ')';
        } else if (val.startsWith('child:')) {
            const name = val.slice(6);
            const c = (t.childCollections || []).find(x => x.name === name);
            if (!c) return;
            obj = c.childObject; prefix = ''; label = (c.label || name); loopName = name;
        }
        if (!obj) return;

        this.relatedObjectLabel = label;
        this.relatedLoopHint = '';
        this.relatedLoading = true;
        try {
            const rows = await getRelatedObjectFields({ objectApiName: obj, tagPrefix: prefix });
            this.relatedFields = this._enrichFields(rows || []);
            // For a child collection, show a real loop example using 2-3 of its fields
            if (loopName) {
                const sample = this.relatedFields.slice(0, 3).map(f => '  ' + f.tag);
                this.relatedLoopHint = sample.length
                    ? ('{{#' + loopName + '}}\n' + sample.join('\n') + '\n{{/' + loopName + '}}')
                    : ('{{#' + loopName + '}} … {{/' + loopName + '}}');
            }
        } catch (err) {
            console.error('getRelatedObjectFields failed', err);
            this.relatedFields = [];
            this.toast('Error', 'Could not load fields for ' + label, 'error');
        } finally {
            this.relatedLoading = false;
        }
    }

    _resetRelated() {
        this.selectedRelatedKey = '';
        this.relatedFields = [];
        this.relatedObjectLabel = '';
        this.relatedLoopHint = '';
        this.relatedLoading = false;
        this.relatedPickerSearch = '';
        this.relatedDropdownOpen = false;
    }

    /* ── Detected-tag shaping + validation ── */

    /* The single place server tag rows become what the Tags tab renders, so the
       initial load and the post-upload refresh cannot drift apart. */
    _shapeParsedFields(rawFields) {
        return (rawFields || []).map(raw => {
            const f = stripNs(raw);
            return {
                ...f,
                typeClass: 'field-type field-type-' + (f.Field_Type__c || 'Field').toLowerCase(),
                rowClass: 'field-row',
                isBroken: false,
                resolvedLabel: '',
                resolvedWhere: '',
                errorText: ''
            };
        });
    }

    /**
     * Annotates every detected tag with the field it will pull from, or the
     * reason it will pull nothing.
     *
     * Best-effort by design: if the check itself fails, the tag list still
     * renders without the extra column. A list of tags with no annotations is
     * far more useful to the author than an error screen.
     */
    async _applyTagValidation(templateId) {
        if (!templateId || !this.hasParsedFields) return;
        // The list this validation describes. If a re-upload replaces it while
        // the call is in flight, the answers belong to a document that is no
        // longer on screen, so they are dropped rather than merged.
        const snapshot = this.parsedFields;
        let rows;
        try {
            rows = await validateTemplateTags({ templateId });
        } catch (e) {
            console.warn('[SignForce] tag validation unavailable', e);
            return;
        }
        if (this.parsedFields !== snapshot) return;

        const byId = new Map((rows || []).map(r => [r.id, r]));
        this.parsedFields = this.parsedFields.map(f => {
            const r = byId.get(f.Id);
            if (!r) return f;
            const ok = r.ok === true;
            return {
                ...f,
                isBroken: !ok,
                rowClass: ok ? 'field-row' : 'field-row field-row-broken',
                resolvedLabel: ok ? r.label : '',
                resolvedWhere: ok ? this._whereText(r) : '',
                errorText: ok ? '' : (r.error || 'This tag could not be matched to a field.')
            };
        });
    }

    _whereText(r) {
        const bits = [];
        if (r.objectLabel) bits.push(r.objectLabel);
        if (r.dataType) bits.push(TYPE_LABELS[r.dataType] || 'Text');
        return bits.join(' · ');
    }

    /* ── Field tree loading ── */
    async loadFieldTree(objectApiName) {
        this._resetRelated();
        if (!objectApiName) {
            this.fieldTree = null;
            return;
        }
        if (this._fieldTreeCache[objectApiName]) {
            this.fieldTree = this._fieldTreeCache[objectApiName];
            return;
        }
        this.isLoadingFieldTree = true;
        try {
            const tree = await getObjectFieldTree({ objectApiName });
            this._fieldTreeCache[objectApiName] = tree;
            this.fieldTree = tree;
        } catch (e) {
            console.error('getObjectFieldTree failed', e);
            this.fieldTree = null;
            this.toast('Error', 'Could not load fields for ' + objectApiName, 'error');
        } finally {
            this.isLoadingFieldTree = false;
        }
    }

    /* ── Click-to-copy handlers ── */
    handleCopyTag(e) {
        e.stopPropagation();
        const tag = e.currentTarget.dataset.tag || (e.target && e.target.dataset && e.target.dataset.tag);
        if (!tag) return;
        this.copyToClipboard(tag);
        // BUG-030/032 ROOT CAUSE: ShowToastEvent's message parses {n}/{...} merge
        // placeholders, so passing a raw tag like {{TODAY}} got mangled and the
        // toast rendered only "}". The clipboard still receives the FULL tag (the
        // copy itself was never broken). Show a brace-free confirmation instead.
        this.toast('Copied to clipboard', 'Merge tag copied - paste it into your document.', 'success');
    }

    handleCopySnippet(e) {
        e.stopPropagation();
        const snippet = e.currentTarget.dataset.snippet;
        if (!snippet) return;
        this.copyToClipboard(snippet);
        this.toast('Copied snippet', 'Loop block ready to paste', 'success');
    }

    copyToClipboard(text) {
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).catch(err => {
                console.warn('Clipboard write failed', err);
                this._fallbackCopy(text);
            });
            return;
        }
        this._fallbackCopy(text);
    }

    _fallbackCopy(text) {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand('copy'); } catch (e) { /* swallow */ }
        document.body.removeChild(ta);
    }

    /* ── File upload + save ── */
    handleFileUploaded(event) {
        const files = event.detail.files;
        if (!files || files.length === 0) return;

        // Issue #6 fix — previously the .then() had no .catch(), so if
        // resolveContentVersionId failed the user saw nothing and the form
        // silently saved without a file. Now we surface the error.
        this.resolveContentVersionId(files[0].documentId)
            .then(cvId => {
                if (!cvId) {
                    this.toast(
                        'Upload error',
                        'File uploaded but we could not link it. Please try again.',
                        'error'
                    );
                    return;
                }
                this.form = {
                    ...this.form,
                    templateFileId: cvId,
                    contentDocumentId: files[0].documentId
                };
                // Parse the merge tags NOW rather than waiting for Save. The
                // Signers and Fields tabs are built from those tags, so making the
                // author save first meant they could open those tabs against a
                // document nothing had read yet.
                this._startTagParse();
            })
            .catch(err => {
                console.error('CV resolution failed', err);
                this.toast(
                    'Upload error',
                    err?.body?.message || err?.message
                    || 'File uploaded but we could not link it. Please try again.',
                    'error'
                );
            });
    }

    /**
     * Registers the template (which queues the tag parse) and waits for it.
     *
     * Registering here is what makes parse-on-upload possible at all: parsing is an
     * @future job keyed on the template Id, so the record has to exist. For a new
     * template that means this upload creates it — the same call Save would have
     * made, just earlier. Save still runs normally afterwards and updates it.
     */
    async _startTagParse() {
        const name = (this.form.name || '').trim();
        const objectApiName = (this.form.objectApiName || '').trim();
        if (!name || !objectApiName) {
            // Nothing to register against yet — fall back to parsing on Save.
            this.toast(
                'Finish Setup first',
                'Add a template name and target object on the Setup tab, then re-upload to read the merge tags.',
                'warning'
            );
            return;
        }

        this.isParsing = true;
        this.tagsReady = false;
        this.parseError = null;
        try {
            const id = await registerTemplate({
                templateId: this.form.id,
                name: name,
                objectApiName: objectApiName,
                contentVersionId: this.form.templateFileId,
                outputFormat: this.form.outputFormat,
                outputFilenamePattern: this.form.outputFilenamePattern,
                active: this.form.active,
                autoCreateAgreement: this.form.autoCreateAgreement,
                defaultAgreementType: this.form.defaultAgreementType,
                description: this.form.description
            });
            this.form = { ...this.form, id };
            this._parseToken = id + ':' + Date.now();
            await this._awaitParse(id, this._parseToken, 0);
        } catch (err) {
            console.error('[SignForce] parse-on-upload failed', err);
            this.isParsing = false;
            this.parseError = err?.body?.message || err?.message || 'Could not read the template.';
            this.toast('Could not read the template', this.parseError, 'error');
        }
    }

    /**
     * Polls until the parse finishes. Same backoff the post-save poller uses —
     * a cold Lambda start on a large DOCX can take a while.
     */
    async _awaitParse(id, token, attempt) {
        const delays = [1200, 2000, 3000, 4000, 6000, 8000, 10000];
        if (attempt >= delays.length) {
            this.isParsing = false;
            this.toast(
                'Still reading the template',
                'Tag detection is taking longer than usual. Save and re-open the template to see the tags.',
                'warning'
            );
            return;
        }
        await new Promise(r => setTimeout(r, delays[attempt]));
        // A newer upload owns the outcome now.
        if (this._parseToken !== token) return;

        let state;
        try {
            state = await getTemplateParseState({ templateId: id });
        } catch (e) {
            console.warn('[SignForce] parse state check failed', e);
            return this._awaitParse(id, token, attempt + 1);
        }
        if (this._parseToken !== token) return;

        if (state && state.error) {
            this.isParsing = false;
            this.parseError = state.error;
            this.toast('Parse error', 'There was a problem reading your DOCX. Check the file and re-upload.', 'error');
            return;
        }
        if (state && state.parsed) {
            this.isParsing = false;
            this.tagsReady = true;
            this.parsedTagCount = state.tagCount || 0;
            await this._refreshParsedTags(id);
            try { await refreshApex(this._wiredTemplates); } catch (e) { /* grid refresh is cosmetic */ }
            const n = this.parsedTagCount;
            this.toast(
                'Tags ready',
                n > 0
                    ? `${n} merge tag${n === 1 ? '' : 's'} detected. Signers and Fields are now available.`
                    : 'No merge tags were found in this document.',
                n > 0 ? 'success' : 'warning'
            );
            return;
        }
        return this._awaitParse(id, token, attempt + 1);
    }

    /**
     * Pulls the freshly detected tags into the Tags tab.
     *
     * Only the tag list and the parse markers are taken — NOT the whole form.
     * _loadTemplateIntoForm rebuilds `form` from the server, which would discard
     * whatever the author has typed on Setup since the upload.
     */
    async _refreshParsedTags(id) {
        try {
            const result = await getTemplate({ templateId: id });
            this.parsedFields = this._shapeParsedFields(result.fields);
            this._applyTagValidation(id);
            const t = stripNs(result.template);
            this.form = {
                ...this.form,
                lastParsedDate: t.Last_Parsed_Date__c
                    ? new Date(t.Last_Parsed_Date__c).toLocaleString()
                    : null,
                lastParseError: t.Last_Parse_Error__c || null
            };
            // The Fields editor renders the stored PDF preview; it was rebuilt for
            // this upload, so drop the id resolved for the previous file.
            this._savedTemplateFileId = t.Template_File_Id__c;
            this.fieldsPreviewFileId = null;
            this._fieldsPreviewSource = null;
        } catch (e) {
            console.warn('[SignForce] could not refresh parsed tags', e);
        }
    }

    async resolveContentVersionId(contentDocumentId) {
        try {
            return await getContentVersionId({ contentDocumentId });
        } catch (e) {
            // Issue #6 fix — previously we swallowed the error and silently
            // fell back to using documentId as-is. That caused the saved
            // template to point at a ContentDocument Id instead of a
            // ContentVersion Id, which broke later parsing/rendering with a
            // confusing "Template file not found" error. Re-throw so the
            // caller can show the user a real toast.
            console.warn('CV resolution failed', e);
            throw e;
        }
    }

    async handleViewTemplateFile() {
        this.showPreviewSection = true;
        this.previewLoading = true;
        this.previewUrl = '';
        this._previewBase64 = null;
        // Bring the preview into view — it renders below the upload card, off the
        // bottom of the modal, so the click otherwise looks like it did nothing.
        this.scrollToPreview();

        // Fast path: a pre-built, Salesforce-stored PDF preview — renders instantly
        // with no Lambda DOCX→PDF round-trip.
        if (this.form.id) {
            try {
                const storedCvId = await getStoredTemplatePreviewCvId({ templateId: this.form.id });
                if (storedCvId) {
                    this.previewUrl = vfPageUrl('PDFPreview') + '?cvId=' + encodeURIComponent(storedCvId) + '&ts=' + Date.now();
                    this.previewLoading = false;
                    return;
                }
            } catch (e) { /* fall through to on-demand */ }
        }

        if (!this.form.templateFileId && !this.form.id) {
            this.previewLoading = false;
            this.toast('Save Required', 'Please save the template first to generate a PDF preview.', 'warning');
            return;
        }

        // Slow path: convert on demand (also works for a just-uploaded, unsaved file).
        getTemplatePreviewUrl({ templateId: this.form.id, contentVersionId: this.form.templateFileId })
            .then(url => {
                this.previewLoading = false;
                if (url && url.startsWith('base64:')) {
                    this._previewBase64 = url.substring(7);
                    this.previewUrl = vfPageUrl('PDFPreview') + '?mode=receive&ts=' + Date.now();
                } else {
                    this._previewBase64 = null;
                    this.previewUrl = url;
                }
            })
            .catch(err => {
                console.error('getTemplatePreviewUrl failed', err);
                this.previewUrl = '';
                this.previewLoading = false;
                this.toast('Preview Error', err.body?.message || err.message || 'Could not load preview', 'error');
            });
    }

    handleClosePreview() {
        this.showPreviewSection = false;
        this.previewUrl = '';
        this.previewLoading = false;
    }

    // Scroll the just-shown preview section into view. Waits for the render with
    // the tracked flag already flipped, so the anchor exists when we query it.
    scrollToPreview() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const anchor = this.template.querySelector('[data-preview-anchor]');
            if (anchor && anchor.scrollIntoView) {
                anchor.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        }, 50);
    }

    _previewBase64 = null;

    /** Once PDFPreview (receive mode) has loaded, hand it the PDF bytes. */
    handlePreviewFrameLoad(event) {
        if (!this._previewBase64) return;
        try {
            event.target.contentWindow.postMessage(JSON.stringify({
                type: 'loadPdfBase64',
                data: this._previewBase64
            }), '*');
        } catch (e) { /* ignore */ }
    }

    /**
     * Save flow:
     *   1. Upsert the template via Apex.
     *   2. Show success toast immediately.
     *   3. Refresh the templates grid so the new/updated card shows up right away.
     *   4. Close the modal.
     *   5. Background-poll for parse completion (since parsing happens in @future).
     *      If parsing produces new tags or an error, surface a toast.
     */
    async handleSave() {
        // Block save if any template-level signer has an invalid/blank email —
        // Signer__c.Email__c is required, so we must validate before persisting
        // the layout JSON. Matches createAgreement / signermanager validation.
        const badSigner = this._firstInvalidSigner();
        if (badSigner) {
            const who = (badSigner.name || '').trim() || 'A signer';
            this.toast(
                'Check the signer email',
                `${who} has an email address that isn't valid. Correct it, or leave it blank to fill in when the agreement is created.`,
                'error'
            );
            this.activeTab = TAB_SIGNERS;
            return;
        }

        // Validate duplicate emails (case-insensitive). Blanks are skipped —
        // several signers may legitimately be left to fill in later.
        const seenEmails = new Set();
        for (const r of this.signerRows) {
            const emailTrim = (r.email || '').trim().toLowerCase();
            if (!emailTrim) continue;
            if (seenEmails.has(emailTrim)) {
                this.toast(
                    'Duplicate signer email',
                    `The email "${r.email}" is used more than once. Each signer must have a unique email address.`,
                    'error'
                );
                this.activeTab = TAB_SIGNERS;
                return;
            }
            seenEmails.add(emailTrim);
        }

        // Every placed field must belong to a signer. An unassigned one is dropped
        // at generation with nothing to show for it, so this is caught here rather
        // than letting the author save a template that silently loses fields.
        const orphanFields = this._unassignedLayoutFields();
        if (orphanFields.length > 0) {
            const n = orphanFields.length;
            const where = orphanFields
                .slice(0, 3)
                .map(f => (f.type || 'Field') + ' on page ' + (f.page || 1))
                .join(', ');
            this.toast(
                n === 1 ? 'Assign this field to a signer' : 'Assign these fields to a signer',
                `${n === 1 ? '1 field is' : n + ' fields are'} not assigned: ${where}`
                + `${n > 3 ? ', and more' : ''}. Select each field on the document and pick a signer under Assign To.`,
                'error'
            );
            this.activeTab = TAB_FIELDS;
            return;
        }

        this.isSaving = true;
        const wasNew = !this.form.id;
        const hadFile = !!this.form.templateFileId;
        // Build the layout JSON now, before closeDialog() resets signerRows.
        const layoutJson = JSON.stringify(this._buildLayout());
        try {
            const id = await registerTemplate({
                templateId: this.form.id,
                name: this.form.name,
                objectApiName: this.form.objectApiName,
                contentVersionId: this.form.templateFileId,
                outputFormat: this.form.outputFormat,
                outputFilenamePattern: this.form.outputFilenamePattern,
                active: this.form.active,
                autoCreateAgreement: this.form.autoCreateAgreement,
                defaultAgreementType: this.form.defaultAgreementType,
                description: this.form.description
            });

            // Persist the template-level signers/fields layout. For a brand-new
            // template the Id only exists now (after registerTemplate returns).
            try {
                await saveTemplateLayout({ templateId: id, layoutJson });
            } catch (layoutErr) {
                // Layout save is additive — surface a soft warning but don't
                // fail the whole template save the user just completed.
                console.warn('[SignForce] saveTemplateLayout failed', layoutErr);
                this.toast(
                    'Signers not saved',
                    layoutErr.body?.message || 'The template saved, but signers could not be stored. Re-open to retry.',
                    'warning'
                );
            }

            // Refresh the grid so the new/edited card shows immediately
            await refreshApex(this._wiredTemplates);

            // Close the modal — primary success path.
            this.closeDialog();

            // Confirm the save, and nothing else. This used to add "Parsing tags
            // in the background…", which stopped being true once tags moved to
            // being read at upload time, and a second toast then repeated the tag
            // count the author had already seen on the Tags tab.
            this.toast('Saved', wasNew ? 'Template created.' : 'Template updated.', 'success');

            // If a file was attached, parse runs in @future. Poll
            // periodically to surface parse errors / tag count change.
            if (hadFile) {
                // Track expected parse so a second save doesn't show toasts
                // from the previous parse cycle.
                this._latestParsePollId = id;
                this._pollParseStatus(id, 0);
            }
        } catch (err) {
            console.error('registerTemplate failed', err);
            this.toast('Error', err.body?.message || err.message || 'Save failed', 'error');
        } finally {
            this.isSaving = false;
        }
    }

    /**
     * Issue #5 fix — previously this was a single setTimeout(.., 4000) call,
     * which had three problems:
     *   1. If the Lambda was slow (cold start, big DOCX) the parse wouldn't
     *      be done in 4 sec and the user saw a stale "no tags" message.
     *   2. If the parse was fast, the user was still waiting 4 sec for
     *      feedback.
     *   3. Only one check ever ran, so errors that surfaced later were
     *      silently lost.
     *
     * Now we poll with exponential-ish backoff: 1.5s, 2.5s, 4s, 6s, 8s, 10s.
     * Total ~32s before giving up — plenty of time for any reasonable
     * Lambda cold start. We stop early as soon as Last_Parsed_Date__c or
     * Last_Parse_Error__c shows up.
     */
    async _pollParseStatus(id, attempt) {
        const delays = [1500, 2500, 4000, 6000, 8000, 10000];
        if (attempt >= delays.length) {
            // Give up — but only show a soft warning, don't error out.
            // (Parse might still be running, the user will see results
            //  on next page load.)
            console.warn('[SignForce] parse status polling timed out for', id);
            return;
        }

        await new Promise(r => setTimeout(r, delays[attempt]));

        // If another save kicked off in the meantime, abandon this poll
        // chain — the newer one will own the toasts.
        if (this._latestParsePollId !== id) return;

        try {
            await refreshApex(this._wiredTemplates);
        } catch (e) {
            console.warn('[SignForce] refreshApex during parse poll failed', e);
            return;
        }

        const updated = (this.templates || []).find(t => t.Id === id);
        if (!updated) return;

        // Parse error surfaced?
        if (updated.Last_Parse_Error__c) {
            this.toast(
                'Parse error',
                'There was a problem parsing your DOCX. Open the template to see details.',
                'error'
            );
            return;
        }

        // Parse finished. Nothing to announce: tags are now read at UPLOAD time,
        // so by the time the author saves they have already seen the count on
        // the Tags tab and been told about it there. Repeating it on save was
        // stale news, and its "click the template card to view" advice pointed
        // at a screen they had just come from. The refreshApex above is the real
        // work here — it updates the tag count on the template card.
        if (updated.Last_Parsed_Date__c) return;

        // Still pending — keep polling.
        return this._pollParseStatus(id, attempt + 1);
    }

    /**
     * @deprecated Replaced by _pollParseStatus (issue #5). Kept here only
     * so any external code or tests calling it don't break. New code should
     * use _pollParseStatus.
     */
    async _postSaveParseCheck(id) {
        return this._pollParseStatus(id, 0);
    }

    async handleDelete() {
        if (!this.form.id) return;

        // Was window.confirm(), then lightning/confirm — the first is unstyleable
        // and blocked by Lightning Web Security, the second is a Salesforce-blue
        // SLDS modal. c-signforce-confirm is the product's own.
        let confirmed = false;
        try {
            confirmed = await this.template.querySelector('c-signforce-confirm').open({
                title: 'Delete this template?',
                message: 'The template and its field mapping are removed. Agreements already created from it are unaffected. This cannot be undone.',
                confirmLabel: 'Delete template',
                variant: 'danger'
            });
        } catch (e) {
            // Never proceed with a destructive action if the prompt itself failed.
            console.warn('confirm dialog failed', e);
            return;
        }
        if (!confirmed) return;

        try {
            await deleteTemplate({ templateId: this.form.id });
            this.toast('Deleted', 'Template removed.', 'success');
            await refreshApex(this._wiredTemplates);
            this.closeDialog();
        } catch (err) {
            this.toast('Error', err.body?.message || 'Delete failed', 'error');
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
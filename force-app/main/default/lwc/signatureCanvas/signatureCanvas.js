// SignForce v6 - force rebuild - 1779087258
import { LightningElement, api, track } from 'lwc';
// Every server call goes through GuestSigningApi: the signer is resolved from the
// link token (plus the per-browser session token for anything that mutates or
// reveals data), never from a client-supplied signerId / email.
import getSignerByTokenSecure from '@salesforce/apex/GuestSigningApi.getSignerByTokenSecure';
import startSigningSession from '@salesforce/apex/GuestSigningApi.startSigningSession';
import validateSigningSession from '@salesforce/apex/GuestSigningApi.validateSigningSession';
import completeSigningSecure from '@salesforce/apex/GuestSigningApi.completeSigningSecure';
import declineAgreementSecure from '@salesforce/apex/GuestSigningApi.declineAgreementSecure';
import saveSignatureSecure from '@salesforce/apex/GuestSigningApi.saveSignatureSecure';
import getSavedSignatureSecure from '@salesforce/apex/GuestSigningApi.getSavedSignatureSecure';
import getFieldsForSignerSecure from '@salesforce/apex/GuestSigningApi.getFieldsForSignerSecure';
import saveFieldValuesSecure from '@salesforce/apex/GuestSigningApi.saveFieldValuesSecure';
import getDocumentVersionSecure from '@salesforce/apex/GuestSigningApi.getDocumentVersionSecure';
import { stripNs, vfPageUrl } from 'c/nsUtils';
import { loadStyle } from 'lightning/platformResourceLoader';
import SIGNATURE_FONTS_URL from '@salesforce/resourceUrl/SignForceSignatureFonts';

/**
 * Scheme guard for a value bound to an img `src`.
 *
 * A signature is always a base64 data:image from the canvas or from a file
 * upload; a logo may be an https URL or a path on this origin. Anything else -
 * javascript:, vbscript:, data:text/html - is dropped rather than handed to the
 * browser. image/svg+xml stays allowed on purpose: script inside an SVG does not
 * execute when the SVG is loaded through <img>.
 */
function safeImageSrc(value) {
    if (typeof value !== 'string') return '';
    const v = value.trim();
    if (v === '') return '';
    if (/^data:image\/[a-z0-9.+-]+[;,]/i.test(v)) return v;
    if (/^https:\/\//i.test(v)) return v;
    if (v.charAt(0) === '/' && v.charAt(1) !== '/') return v;
    return '';
}

export default class SignatureCanvas extends LightningElement {
    @api token;
    @api signerEmail;
    @api signerId;
    @api label;
    @api agreementName;

    @track isLoading = true;
    @track hasError = false;
    @track isSigned = false;
    @track errorMessage = '';
    @track internalAgreementName = '';
    @track internalSignerId = '';
    @track internalSignerEmail = '';
    @track internalAgreementId = '';

    // Token actually in use (URL ?token= wins over the @api property) and the
    // session token GuestSigningApi hands back once this browser owns the link.
    activeToken = '';
    sessionToken = '';

    // Document
    @track hasDocument = false;
    @track documentPreviewUrl = '';

    // Fields
    @track signerFields = [];
    @track hasFields = false;

    // Signature pad
    @track showDraw = true;
    @track showType = false;
    @track showUpload = false;
    @track paths = [];
    @track showDrawPlaceholder = true;
    @track typedName = '';
    @track selectedFont = '';
    @track uploadedImage = null;

    // Bound by the template instead of uploadedImage itself: the value comes
    // from FileReader or from a stored signature, so the scheme is checked on
    // the way into the DOM.
    get safeUploadedImage() {
        return safeImageSrc(this.uploadedImage);
    }

    @track isDragOver = false;

    // Pen settings
    @track penColor = '#0a1628';
    @track penWidth = 2.5;

    // Saved signature
    @track hasSavedSignature = false;
    @track savedSignatureData = '';
    @track savedSignatureType = '';
    @track savedFontFamily = '';
    @track showUseSaved = false;

    // Active field drawing
    activeFieldId = null;
    isDrawingField = false;
    fieldPaths = {};
    fieldCurrentPath = '';
    fieldPathId = 0;

    isDrawing = false;
    currentPath = '';
    currentPathId = 0;
    usingSavedSignature = false;

    /* ── Getters: status / progress ─────────────────────── */
    get completionStatus() {
        const total = this.signerFields.filter(f => f.Is_Required__c).length;
        const done = this.signerFields.filter(f => f.Is_Required__c && f.Is_Completed__c).length;
        return done + ' of ' + total + ' fields complete';
    }
    get badgeLabel() {
        const total = this.signerFields.filter(f => f.Is_Required__c).length;
        const done = this.signerFields.filter(f => f.Is_Required__c && f.Is_Completed__c).length;
        return done === total && total > 0 ? 'Ready to sign' : 'In progress';
    }
    get statusPillClass() {
        const total = this.signerFields.filter(f => f.Is_Required__c).length;
        const done = this.signerFields.filter(f => f.Is_Required__c && f.Is_Completed__c).length;
        return (done === total && total > 0)
            ? 'sc-status-pill sc-status-pill-ready'
            : 'sc-status-pill';
    }

    /* ── Tab classes ───────────────────────────────────── */
    get drawTabClass() { return 'sc-tab' + (this.showDraw ? ' sc-tab-active' : ''); }
    get typeTabClass() { return 'sc-tab' + (this.showType ? ' sc-tab-active' : ''); }
    get uploadTabClass() { return 'sc-tab' + (this.showUpload ? ' sc-tab-active' : ''); }

    /* ── Font option classes (8 styles) ─────────────────── */
    fontClass(name) {
        return 'sc-font-option' + (this.selectedFont === name ? ' sc-font-option-active' : '');
    }
    get font1Class() { return this.fontClass('Dancing Script'); }
    get font2Class() { return this.fontClass('Great Vibes'); }
    get font3Class() { return this.fontClass('Pacifico'); }
    get font4Class() { return this.fontClass('Caveat'); }
    get font5Class() { return this.fontClass('Allura'); }
    get font6Class() { return this.fontClass('Satisfy'); }
    get font7Class() { return this.fontClass('Kaushan Script'); }
    get font8Class() { return this.fontClass('Sacramento'); }

    /* ── Pen color / thickness classes ──────────────────── */
    get colorBlackClass() { return 'sc-color-swatch' + (this.penColor === '#0a1628' ? ' sc-color-swatch-active' : ''); }
    get colorBlueClass() { return 'sc-color-swatch' + (this.penColor === '#1d4ed8' ? ' sc-color-swatch-active' : ''); }
    get colorRedClass() { return 'sc-color-swatch' + (this.penColor === '#b91c1c' ? ' sc-color-swatch-active' : ''); }
    get thin1Class() { return 'sc-thickness-btn' + (this.penWidth === 1.5 ? ' sc-thickness-btn-active' : ''); }
    get thin2Class() { return 'sc-thickness-btn' + (this.penWidth === 2.5 ? ' sc-thickness-btn-active' : ''); }
    get thin3Class() { return 'sc-thickness-btn' + (this.penWidth === 4 ? ' sc-thickness-btn-active' : ''); }

    /* ── Canvas active state ────────────────────────────── */
    get canvasWrapClass() {
        return 'sc-canvas-wrap' + (this.paths.length > 0 ? ' sc-canvas-active' : '');
    }

    /* ── Lifecycle ──────────────────────────────────────── */
    connectedCallback() {
        // Typed-signature fonts, loaded from this package's own static resource
        // instead of fonts.googleapis.com - a packaged app must not pull styling
        // from a third-party host. loadStyle replaces the hand-built <link>,
        // which is the supported way to bring in a static-resource stylesheet.
        // Every font-family declaration keeps its 'cursive' fallback, so a load
        // failure degrades the lettering rather than blocking signing.
        loadStyle(this, SIGNATURE_FONTS_URL + '/fonts.css').catch(() => {
            // Non-fatal by design - see the fallback note above.
        });

        const url = new URL(window.location.href);
        const urlToken = url.searchParams.get('token');
        const tok = urlToken || this.token;
        if (tok) {
            this.loadSignerData(tok);
        } else {
            this.errorMessage = 'Invalid signing link.';
            this.hasError = true;
            this.isLoading = false;
        }
    }

    async loadSignerData(tok) {
        // BUG-033 FIX: Reset previous signer/agreement context to defaults
        // BEFORE making the server call. Pehle if the LWC instance was reused
        // across signing links (e.g. one Site session opening agreement A
        // then agreement B), the old internalSignerEmail / agreementName /
        // signerId could briefly leak into UI before the new data resolved,
        // and any failures in resolution would leave stale state intact.
        this.internalSignerId = null;
        this.internalSignerEmail = '';
        this.internalAgreementId = null;
        this.internalAgreementName = '';
        this.signerFields = [];
        this.hasError = false;
        this.errorMessage = '';
        this.activeToken = tok;
        this.sessionToken = '';

        try {
            const result = stripNs(await getSignerByTokenSecure({ token: tok }));
            if (result.error) {
                // Inline strips: the scanner does not trace helper functions, so
                // the sanitiser sits directly on the assignment into the template.
                this.errorMessage = String(result.error || '').replace(/[<>&`]/g, '');
                this.hasError = true;
            } else {
                this.internalSignerId = result.signerId;
                this.internalAgreementName = String(result.agreementName || '').replace(/[<>&`]/g, '');
                this.internalSignerEmail = String(result.signerEmail || '').replace(/[<>&"'`]/g, '');
                this.internalAgreementId = result.agreementId;

                // Only REUSE a session here. Claiming one is left to a real signer
                // gesture (complete / decline) so an email scanner opening the link
                // cannot consume the single-browser binding first.
                await this.reuseStoredSession(tok);

                await Promise.all([
                    this.loadDocument(),
                    this.loadFields(),
                    this.loadSavedSignature()
                ]);
            }
        } catch (e) {
            this.errorMessage = 'Failed to load document. Please try again.';
            this.hasError = true;
        } finally {
            this.isLoading = false;
        }
    }

    /* ── Signing session (single-browser binding) ───────── */

    _sessionKey(tok) { return 'sf_session_' + tok; }

    /** True when THIS browser already owns the binding. Never claims a new one. */
    async reuseStoredSession(tok) {
        let stored = null;
        try { stored = window.localStorage.getItem(this._sessionKey(tok)); } catch (e) { /* storage blocked */ }
        if (!stored) return false;
        try {
            const valid = await validateSigningSession({ token: tok, sessionToken: stored });
            if (valid) { this.sessionToken = stored; return true; }
        } catch (e) { /* treat as stale */ }
        try { window.localStorage.removeItem(this._sessionKey(tok)); } catch (e) { /* ignore */ }
        return false;
    }

    /** Claims the link for this browser. False means another browser got there first. */
    async claimSession(tok) {
        try {
            const newToken = await startSigningSession({ token: tok });
            if (newToken) {
                try { window.localStorage.setItem(this._sessionKey(tok), newToken); } catch (e) { /* ignore */ }
                this.sessionToken = newToken;
                return true;
            }
        } catch (e) { /* fall through */ }
        return false;
    }

    /** Reuse or claim; sets the session error and returns false when neither works. */
    async ensureSession() {
        if (this.sessionToken) return true;
        const tok = this.activeToken;
        if (await this.reuseStoredSession(tok)) return true;
        if (await this.claimSession(tok)) return true;
        this.errorMessage = 'This signing link is already open in another browser or window. Please continue there, or ask the sender to resend the link.';
        this.hasError = true;
        return false;
    }

    /** GuestSigningApi throws the literal SESSION_REQUIRED when the binding is missing/mismatched. */
    isSessionError(e) {
        const msg = (e && e.body && e.body.message) || (e && e.message) || '';
        return String(msg).indexOf('SESSION_REQUIRED') !== -1;
    }

    handleSessionLost() {
        this.sessionToken = '';
        try { window.localStorage.removeItem(this._sessionKey(this.activeToken)); } catch (e) { /* ignore */ }
        this.errorMessage = 'Your signing session has expired or was opened elsewhere. Please reload the page from your signing link.';
        this.hasError = true;
    }

    async loadDocument() {
        try {
            const cvId = await getDocumentVersionSecure({ token: this.activeToken });
            if (cvId) {
                this.hasDocument = true;
                this.documentPreviewUrl = vfPageUrl('PDFPreview') + '?cvId=' + cvId + '&ts=' + Date.now();
            }
        } catch (e) {
            console.log('No document found');
        }
    }

    async loadFields() {
        try {
            const fields = stripNs(await getFieldsForSignerSecure({ token: this.activeToken }));
            if (fields && fields.length > 0) {
                this.hasFields = true;
                this.signerFields = fields.map(f => this.decorateField({
                    ...f,
                    isSignature: f.Field_Type__c === 'Signature' || f.Field_Type__c === 'Initial',
                    isText: ['Full Name', 'Email', 'Company', 'Title', 'Text Box'].includes(f.Field_Type__c),
                    isDate: f.Field_Type__c === 'Date Signed',
                    isCheckbox: f.Field_Type__c === 'Checkbox',
                    paths: [],
                    isEmpty: true,
                    isChecked: false,
                    placeholder: this.getPlaceholder(f.Field_Type__c),
                    Field_Value__c: f.Field_Type__c === 'Date Signed' ? new Date().toLocaleDateString() : (f.Field_Value__c || ''),
                    Is_Completed__c: f.Field_Type__c === 'Date Signed' ? true : f.Is_Completed__c
                }));
            }
        } catch (e) {
            console.log('No fields found');
        }
    }

    /** Adds containerClass / dotClass derived from Is_Completed__c */
    decorateField(f) {
        const done = !!f.Is_Completed__c;
        return {
            ...f,
            containerClass: 'sc-field' + (done ? ' sc-field-complete' : ''),
            dotClass: 'sc-field-dot' + (done ? ' sc-field-dot-done' : '')
        };
    }

    async loadSavedSignature() {
        // BUG-033 FIX: Pehle agar component instance reused hota tha (e.g.
        // user opens a second signing link in same tab/session without a
        // full page reload), `savedSignatureData` aur baaki saved-signature
        // state previous agreement ka stale value rakhta tha. Even if the
        // server call returned no signature for new email, banner UI showed
        // the old data. Explicitly reset ALL saved-signature state before
        // calling the server so we have a clean slate per email lookup.
        this.hasSavedSignature = false;
        this.savedSignatureData = '';
        this.savedSignatureType = '';
        this.savedFontFamily = '';
        this.showUseSaved = false;
        this.usingSavedSignature = false;

        // Needs the bound session: without it there is nothing to look up yet.
        if (!this.sessionToken) return;

        try {
            const saved = stripNs(await getSavedSignatureSecure({ token: this.activeToken, sessionToken: this.sessionToken }));
            if (saved && saved.found) {
                this.hasSavedSignature = true;
                this.savedSignatureData = saved.signatureData;
                this.savedSignatureType = saved.signatureType;
                this.savedFontFamily = saved.fontFamily;
                this.showUseSaved = true;
            }
        } catch (e) {
            console.log('No saved signature');
        }
    }

    getPlaceholder(fieldType) {
        const map = {
            'Full Name': 'Enter your full name',
            'Email': 'Enter your email',
            'Company': 'Enter company name',
            'Title': 'Enter your title',
            'Text Box': 'Enter text'
        };
        return map[fieldType] || 'Enter value';
    }

    /* ── Inline-field drawing ───────────────────────────── */
    startSign(e) {
        e.preventDefault();
        const fieldId = e.currentTarget.dataset.id;
        this.activeFieldId = fieldId;
        this.isDrawingField = true;
        if (!this.fieldPaths[fieldId]) this.fieldPaths[fieldId] = [];

        const el = e.currentTarget;
        const rect = el.getBoundingClientRect();
        const x = Math.round((e.clientX - rect.left) * (600 / rect.width));
        const y = Math.round((e.clientY - rect.top) * (100 / rect.height));
        this.fieldCurrentPath = `M ${x} ${y}`;
        this.fieldPathId++;

        const newPath = { id: this.fieldPathId, d: this.fieldCurrentPath };
        this.fieldPaths[fieldId] = [...(this.fieldPaths[fieldId] || []), newPath];
        this.updateFieldPaths(fieldId);
        try { e.currentTarget.setPointerCapture(e.pointerId); } catch (_) { }
    }

    drawSign(e) {
        if (!this.isDrawingField || !this.activeFieldId) return;
        e.preventDefault();
        const fieldId = this.activeFieldId;
        const el = e.currentTarget;
        const rect = el.getBoundingClientRect();
        const x = Math.round((e.clientX - rect.left) * (600 / rect.width));
        const y = Math.round((e.clientY - rect.top) * (100 / rect.height));
        this.fieldCurrentPath += ` L ${x} ${y}`;
        this.fieldPaths[fieldId] = this.fieldPaths[fieldId].map(p =>
            p.id === this.fieldPathId ? { ...p, d: this.fieldCurrentPath } : p
        );
        this.updateFieldPaths(fieldId);
    }

    stopSign() { this.isDrawingField = false; }

    updateFieldPaths(fieldId) {
        this.signerFields = this.signerFields.map(f =>
            f.Id === fieldId
                ? this.decorateField({ ...f, paths: this.fieldPaths[fieldId], isEmpty: false })
                : f
        );
    }

    clearSignField(e) {
        const fieldId = e.currentTarget.dataset.id;
        this.fieldPaths[fieldId] = [];
        this.signerFields = this.signerFields.map(f =>
            f.Id === fieldId ? this.decorateField({ ...f, paths: [], isEmpty: true }) : f
        );
    }

    applySignField(e) {
        const fieldId = e.currentTarget.dataset.id;
        const paths = this.fieldPaths[fieldId] || [];
        if (paths.length === 0) return;
        const value = JSON.stringify(paths);
        this.signerFields = this.signerFields.map(f =>
            f.Id === fieldId
                ? this.decorateField({ ...f, Is_Completed__c: true, Field_Value__c: value })
                : f
        );
    }

    resetField(e) {
        const fieldId = e.currentTarget.dataset.id;
        this.fieldPaths[fieldId] = [];
        this.signerFields = this.signerFields.map(f =>
            f.Id === fieldId
                ? this.decorateField({ ...f, Is_Completed__c: false, Field_Value__c: '', paths: [], isEmpty: true })
                : f
        );
    }

    handleFieldValueChange(e) {
        const fieldId = e.currentTarget.dataset.id;
        const value = e.target.value;
        this.signerFields = this.signerFields.map(f =>
            f.Id === fieldId
                ? this.decorateField({ ...f, Field_Value__c: value, Is_Completed__c: value.trim().length > 0 })
                : f
        );
    }

    handleCheckboxChange(e) {
        const fieldId = e.currentTarget.dataset.id;
        const checked = e.target.checked;
        this.signerFields = this.signerFields.map(f =>
            f.Id === fieldId
                ? this.decorateField({ ...f, isChecked: checked, Field_Value__c: checked ? 'true' : '', Is_Completed__c: checked })
                : f
        );
    }

    /* ── Main signature pad ─────────────────────────────── */
    getCoords(e) {
        const el = e.currentTarget;
        const rect = el.getBoundingClientRect();
        return {
            x: Math.round((e.clientX - rect.left) * (640 / rect.width)),
            y: Math.round((e.clientY - rect.top) * (220 / rect.height))
        };
    }

    startDraw(e) {
        e.preventDefault();
        this.isDrawing = true;
        this.showDrawPlaceholder = false;
        const pos = this.getCoords(e);
        this.currentPath = `M ${pos.x} ${pos.y}`;
        this.currentPathId++;
        this.paths = [...this.paths, { id: this.currentPathId, d: this.currentPath }];
        try { e.currentTarget.setPointerCapture(e.pointerId); } catch (_) { }
    }

    draw(e) {
        if (!this.isDrawing) return;
        e.preventDefault();
        const pos = this.getCoords(e);
        this.currentPath += ` L ${pos.x} ${pos.y}`;
        this.paths = this.paths.map(p =>
            p.id === this.currentPathId ? { ...p, d: this.currentPath } : p
        );
    }

    stopDraw() { this.isDrawing = false; }

    clearDraw() {
        this.paths = [];
        this.currentPath = '';
        this.showDrawPlaceholder = true;
    }

    selectColor(e) {
        this.penColor = e.currentTarget.dataset.color;
    }

    selectWidth(e) {
        this.penWidth = parseFloat(e.currentTarget.dataset.width);
    }

    selectDraw() {
        this.showDraw = true;
        this.showType = false;
        this.showUpload = false;
        this.paths = [];
        this.showDrawPlaceholder = true;
    }
    selectType() {
        this.showDraw = false;
        this.showType = true;
        this.showUpload = false;
    }
    selectUpload() {
        this.showDraw = false;
        this.showType = false;
        this.showUpload = true;
    }

    handleTypedName(e) { this.typedName = e.target.value; this.selectedFont = ''; }

    /** First letter of each whitespace-separated word, max 4 */
    get typedInitials() {
        if (!this.typedName) return '';
        const parts = this.typedName.trim().split(/\s+/).filter(Boolean);
        return parts.slice(0, 4).map(w => w.charAt(0).toUpperCase()).join('');
    }

    /** Stable per-session envelope identifier (32-hex stamp, SignForce-style) */
    get envelopeId() {
        if (!this._envelopeId) {
            const rand = () => Math.floor(Math.random() * 16).toString(16).toUpperCase();
            let hex = '';
            for (let i = 0; i < 32; i++) hex += rand();
            this._envelopeId = hex;
        }
        return this._envelopeId;
    }
    selectFont1() { this.selectedFont = 'Dancing Script'; }
    selectFont2() { this.selectedFont = 'Great Vibes'; }
    selectFont3() { this.selectedFont = 'Pacifico'; }
    selectFont4() { this.selectedFont = 'Caveat'; }
    selectFont5() { this.selectedFont = 'Allura'; }
    selectFont6() { this.selectedFont = 'Satisfy'; }
    selectFont7() { this.selectedFont = 'Kaushan Script'; }
    selectFont8() { this.selectedFont = 'Sacramento'; }

    triggerFileUpload() { this.template.querySelector('#sig-upload').click(); }

    handleFileUpload(e) {
        this._readImageFile(e.target.files && e.target.files[0]);
    }

    // BUG-021 FIX: the dropzone advertised "Or drop a file here" but had no
    // drag handlers, so dropping did nothing. Wire drop + dragover here and
    // reuse the same reader the file picker uses.
    handleDragOver(e) {
        e.preventDefault();
        this.isDragOver = true;
    }
    handleDragLeave() {
        this.isDragOver = false;
    }
    handleDrop(e) {
        e.preventDefault();
        this.isDragOver = false;
        const dt = e.dataTransfer;
        this._readImageFile(dt && dt.files && dt.files[0]);
    }

    _readImageFile(file) {
        if (!file) return;
        // Only images — the picker already restricts this, but a drop can be anything.
        if (file.type && file.type.indexOf('image/') !== 0) return;
        const reader = new FileReader();
        reader.onload = (evt) => { this.uploadedImage = evt.target.result; };
        reader.readAsDataURL(file);
    }

    get dropzoneClass() {
        return this.isDragOver
            ? 'sc-upload-dropzone sc-upload-dropzone--over'
            : 'sc-upload-dropzone';
    }
    // BUG-026 FIX: clearing `uploadedImage` wasn't enough — the file input
    // element still cached the last filename. Picking the same file again
    // wouldn't fire `change`, so the user couldn't retry. Reset the input's
    // value too so the next selection always triggers a change event.
    clearUpload() {
        this.uploadedImage = null;
        const input = this.template.querySelector('#sig-upload');
        if (input) input.value = '';
    }

    handleUseSaved() {
        this.showUseSaved = false;
        this.usingSavedSignature = true;
        if (this.savedSignatureType === 'Draw') {
            this.showDraw = true;
            this.showType = false;
            this.showUpload = false;
            this.showDrawPlaceholder = false;
            try { this.paths = JSON.parse(this.savedSignatureData); } catch (e) { this.paths = []; }
        } else if (this.savedSignatureType === 'Type') {
            this.showDraw = false;
            this.showType = true;
            this.showUpload = false;
            const parts = this.savedSignatureData.split(':');
            this.typedName = parts[1] || '';
            this.selectedFont = parts[2] || 'Dancing Script';
        } else if (this.savedSignatureType === 'Upload') {
            this.showDraw = false;
            this.showType = false;
            this.showUpload = true;
            // Only ever render a genuine data: image URL here. The file-upload
            // path always produces one via FileReader.readAsDataURL, but this
            // value round-trips through Saved_Signature__c, so don't trust it
            // blindly before it lands in the <img src> below.
            this.uploadedImage = /^data:image\//i.test(this.savedSignatureData || '')
                ? this.savedSignatureData
                : null;
        }
    }

    /* ── Complete / Decline ─────────────────────────────── */
    validateSignature() {
        const unfinished = this.signerFields.filter(f => f.Is_Required__c && !f.Is_Completed__c);
        if (unfinished.length > 0) {
            this.errorMessage = 'Please complete all required fields before signing. ' + unfinished.length + ' field(s) remaining.';
            this.hasError = true;
            return false;
        }
        if (this.usingSavedSignature) return true;
        if (this.showDraw && this.paths.length === 0) {
            this.errorMessage = 'Please draw your signature before completing.';
            this.hasError = true;
            return false;
        }
        if (this.showType && (!this.typedName || !this.selectedFont)) {
            this.errorMessage = 'Please type your name and select a signature style.';
            this.hasError = true;
            return false;
        }
        if (this.showUpload && !this.uploadedImage) {
            this.errorMessage = 'Please upload your signature image.';
            this.hasError = true;
            return false;
        }
        return true;
    }

    async handleComplete() {
        this.hasError = false;
        if (!this.validateSignature()) return;
        if (!(await this.ensureSession())) return;
        try {
            if (this.signerFields.length > 0) {
                const fieldValues = this.signerFields.map(f => ({
                    id: f.Id,
                    value: f.Field_Value__c || ''
                }));
                await saveFieldValuesSecure({ token: this.activeToken, fieldValuesJson: JSON.stringify(fieldValues) });
            }

            let sigData = '';
            let sigType = 'Draw';
            let fontFamily = '';
            if (this.showDraw) {
                sigType = 'Draw';
                sigData = this.paths.length > 0 ? JSON.stringify(this.paths) : this.savedSignatureData;
            } else if (this.showType) {
                sigType = 'Type';
                sigData = 'typed:' + this.typedName + ':' + this.selectedFont;
                fontFamily = this.selectedFont;
            } else if (this.showUpload) {
                sigType = 'Upload';
                sigData = this.uploadedImage || '';
            }

            if (sigData) {
                try {
                    await saveSignatureSecure({
                        token: this.activeToken,
                        sessionToken: this.sessionToken,
                        signatureData: sigData,
                        signatureType: sigType,
                        fontFamily: fontFamily
                    });
                } catch (e) {
                    if (this.isSessionError(e)) { this.handleSessionLost(); return; }
                    console.error(e);
                }
            }

            // Marks this signer signed and, when the envelope is complete, queues
            // certificate + stamping + completion emails server-side. No separate
            // email call is needed here.
            await completeSigningSecure({
                token: this.activeToken,
                sessionToken: this.sessionToken,
                ipAddress: '',
                userAgent: navigator.userAgent,
                ipAddressV4: ''
            });

            this.isSigned = true;
        } catch (e) {
            if (this.isSessionError(e)) { this.handleSessionLost(); return; }
            this.errorMessage = 'Error completing signature. Please try again.';
            this.hasError = true;
        }
    }

    async handleDecline() {
        const reason = await this.template.querySelector('c-signforce-confirm').open({
            title: 'Decline to sign',
            message: 'The sender will be told you declined. Let them know why - this is shared with them.',
            input: true,
            placeholder: 'Reason for declining',
            required: true,
            confirmLabel: 'Decline',
            variant: 'danger'
        });
        if (reason === null) return;   // cancelled
        if (!(await this.ensureSession())) return;

        try {
            await declineAgreementSecure({ token: this.activeToken, sessionToken: this.sessionToken, reason: reason });
            this.errorMessage = 'You have declined to sign this document.';
            this.hasError = true;
        } catch (e) {
            if (this.isSessionError(e)) { this.handleSessionLost(); return; }
            this.errorMessage = 'Error processing decline.';
            this.hasError = true;
        }
    }
}
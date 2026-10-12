// ══════════════════════════════════════════════════════════════════════════
// signingViewer.js
//
// Guest signing portal — drag-and-drop signature placement + PDF preview +
// post-sign flow.
//
// SECURITY MIGRATION (Phase 2):
//   All @AuraEnabled calls now go through GuestSigningApi, which
//   validates the signer's token on every call. No method here trusts
//   client-supplied signerId/agreementId/email anymore. The token in the
//   URL is the security boundary.
//
//   Methods replaced:
//     AgreementController.getSignerByToken          → getSignerByTokenSecure(token)
//     AgreementController.getS3PreviewUrl           → getS3PreviewUrlSecure(token)
//     AgreementController.markSigned                ┐
//     AgreementController.generateStampedPDFServerInternal │ → completeSigningSecure(token, ip, ua)
//     SignedAgreementPDFController.generateAndAttachPDF │ (single bundled call)
//     AgreementController.sendCompletionEmailsWithPDF   ┘
//     AgreementController.declineAgreement          → declineAgreementSecure(token, reason)
//     AgreementController.saveSignature             → saveSignatureSecure(token, ...)
//     AgreementController.getSavedSignature         → getSavedSignatureSecure(token)
//     AgreementController.getPdfFileInfo            → getPdfFileInfoSecure(token, cvId)
//     AgreementController.proxyPdfViaLambda         → proxyPdfViaLambdaSecure(token, cvId)
//     BrandingService.getBrandingForLWC             → getBrandingForGuest()
//   (On the guest path, stamping runs in AgreementControllerGuest.generateStampedPDFServerGuest.)
//
// FIELD ALIGNMENT FIX (unchanged from prior patch):
//   updateFieldPositions now falls back to REFERENCE_PAGE_WIDTH (762) instead
//   of viewerPageWidth, so scale is computed against a known reference
//   regardless of viewer render width.
// ══════════════════════════════════════════════════════════════════════════

import { LightningElement, api, track, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { loadScript, loadStyle } from 'lightning/platformResourceLoader';
import PDFJS_LIB from '@salesforce/resourceUrl/pdfjs';
import SIGNATURE_FONTS_URL from '@salesforce/resourceUrl/SignForceSignatureFonts';
import PDFJS_WORKER from '@salesforce/resourceUrl/pdfjs_worker';
// pdf.js standard (Foxit/Liberation) fonts. Needed so NON-embedded standard-font
// text (Helvetica/Times — common in LibreOffice-converted PDFs) renders instead
// of disappearing. Without standardFontDataUrl, pdf.js logs "fetchStandardFontData
// failed (undefinedFoxitSans.pfb)" and the page shows blank text.
import PDFJS_STD_FONTS from '@salesforce/resourceUrl/pdfjs_standard_fonts';
// Same fonts as base64 in a JS file. Loaded via loadScript (LWS-allowed) so a
// fetch shim can hand them to pdf.js without a network request — the guest
// Experience site's LWS blocks fetching the font resource URL directly.
import PDFJS_FONTS_DATA from '@salesforce/resourceUrl/pdfjs_fonts_data';

// All calls now go through GuestSigningApi (token-validated).
import getSignerByToken from '@salesforce/apex/GuestSigningApi.getSignerByTokenSecure';
import getFieldsForSigner from '@salesforce/apex/GuestSigningApi.getFieldsForSignerSecure';
import getOtherCompletedFields from '@salesforce/apex/GuestSigningApi.getOtherCompletedFieldsSecure';
import getDocumentVersion from '@salesforce/apex/GuestSigningApi.getDocumentVersionSecure';
import getSigningPdfUrl from '@salesforce/apex/GuestSigningApi.getSigningPdfUrlSecure';
import saveFieldValues from '@salesforce/apex/GuestSigningApi.saveFieldValuesSecure';
import declineAgreement from '@salesforce/apex/GuestSigningApi.declineAgreementSecure';
import saveSignature from '@salesforce/apex/GuestSigningApi.saveSignatureSecure';
import getSavedSignature from '@salesforce/apex/GuestSigningApi.getSavedSignatureSecure';
import completeSigning from '@salesforce/apex/GuestSigningApi.completeSigningSecure';
import generateCertificate from '@salesforce/apex/GuestSigningApi.generateSigningCertificateSecure';
import logConsentAccepted from '@salesforce/apex/GuestSigningApi.logConsentAccepted';
import getPdfFileInfo from '@salesforce/apex/GuestSigningApi.getPdfFileInfoSecure';
import proxyPdfViaLambda from '@salesforce/apex/GuestSigningApi.proxyPdfViaLambdaSecure';
import proxyS3Pdf from '@salesforce/apex/GuestSigningApi.proxyS3PdfViaLambdaSecure';
import getCloudDocChunk from '@salesforce/apex/GuestSigningApi.getCloudDocChunkSecure';
import getBranding from '@salesforce/apex/GuestSigningApi.getBrandingForGuest';
import startSigningSession from '@salesforce/apex/GuestSigningApi.startSigningSession';
import validateSigningSession from '@salesforce/apex/GuestSigningApi.validateSigningSession';
import sendSigningOtp from '@salesforce/apex/GuestSigningApi.sendSigningOtp';
import verifySigningOtp from '@salesforce/apex/GuestSigningApi.verifySigningOtp';
import { stripNs, vfPageUrl } from 'c/nsUtils';

// Must match REFERENCE_PAGE_WIDTH in documentEditor.js
const REFERENCE_PAGE_WIDTH = 762;

// Fonts the "Select Style" dropdown offers. Typed-signature font is stored as
// free text inside Field_Value__c ('typed:<name>:<font>') and, for the
// read-only "other signers" layer, that value was written by a DIFFERENT
// signer and is rendered straight into this signer's `style` attribute
// (see updateFieldPositions/updateOtherFieldPositions and selectedFontStyle
// below). Allowlisting against this fixed list before it reaches any style
// string keeps a malicious Field_Value__c from injecting arbitrary CSS into
// another signer's page.
const SIGNATURE_FONTS = ['Dancing Script', 'Great Vibes', 'Pacifico', 'Caveat'];
const safeSignatureFont = (font) => (SIGNATURE_FONTS.includes(font) ? font : SIGNATURE_FONTS[0]);

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

export default class SigningViewer extends LightningElement {
    @track brandName = 'eSignforce';
    @track brandPrimaryColor = '#0a1628';
    @track brandAccentColor = '#f59e0b';
    @track brandLogoUrl = '';

    @track loadingMessage = 'Loading document...';
    @api token;
    @api signerEmail;
    @api signerId;
    @api label;
    @api agreementName;

    @track isLoading = true;
    @track hasError = false;
    @track isSigned = false;
    // True only when this signature was the last one outstanding. Drives which
    // confirmation the signer sees — see completeSigning().
    @track agreementFullySigned = false;
    @track sessionTimedOut = false;
    sessionToken = '';
    _bootstrapped = false;
    _pageRefArrived = false;
    _pageRefToken = null;
    _pdfLibPromise = null;
    _pdfDoc = null;
    _pdfSource = null;
    _pdfRendered = false;
    _pdfRendering = false;
    _pdfFailed = false;
    _resizeTimer = null;
    @track errorMessage = '';
    @track internalAgreementName = '';
    @track internalSignerId = '';
    @track internalSignerEmail = '';
    @track internalSignerName = '';
    @track internalAgreementId = '';

    @track iframeHeight = 1100;
    @track iframeUrl = '';
    @track zoomPct = 100;
    _pendingBase64 = null;
    @track pagePositions = [];
    @track signerFields = [];
    @track otherFields = [];   // read-only: previous signers' completed fields

    @track showBottomSheet = false;
    @track activeFieldId = null;
    @track fieldInputValue = '';

    // ── Email verification (OTP) gate state ──
    // Shown after the session decision but before ANY document content: the
    // emailed one-time code proves the person holding this link also controls
    // the signer's inbox. Skipped when the server says OTP_Verified__c is
    // already true (otpVerified in the token payload).
    @track showOtpGate = false;
    @track otpMaskedEmail = '';
    @track otpError = '';
    @track otpLocked = false;
    @track attemptsLeft = null;
    @track resendCooldown = 0;      // seconds left before Resend re-enables
    @track otpCode = '';
    @track otpVerifying = false;
    @track otpSending = false;
    otpVerified = false;            // from the token payload; no re-render needed
    _otpCooldownTimer = null;
    _otpFocused = false;
    // True when the session was already held at bootstrap: the payload load is
    // deferred until the code is verified (nothing moves behind the gate).
    _otpPayloadDeferred = false;

    // E-sign consent gate state
    @track consentGiven = false;    // true once signer clicks Continue
    @track consentChecked = false;  // the "I agree" checkbox
    // Continue now claims the signing session and loads the document, so it is
    // no longer instant. Guards against a double-click firing two claims.
    _consentBusy = false;
    @track checkboxValue = false;

    @track showDraw = false;
    @track showType = true;
    @track showUpload = false;
    @track paths = [];
    @track showDrawPlaceholder = true;
    @track typedName = '';
    @track typedInitials = '';
    _initialsEdited = false;
    @track selectedFont = '';
    @track uploadedImage = null;

    // Bound by the template instead of uploadedImage itself: the value comes
    // from FileReader or from a stored signature, so the scheme is checked on
    // the way into the DOM.
    get safeUploadedImage() {
        return safeImageSrc(this.uploadedImage);
    }

    // When ON, adopting a signature/initial fills ALL of this signer's
    // same-type fields at once (so they don't sign each box individually).
    @track applyToAll = true;

    @track signedTimestamp = '';
    @track signerIpAddress = '';

    isDrawing = false;
    currentPath = '';
    currentPathId = 0;
    isSubmitting = false;

    @track envelopeId = '';
    @track signedCertificateId = '';

    /* ── Getters ── */

    get displayAgreementName() { return this.internalAgreementName; }
    get activeField() { return this.signerFields.find(f => f && f.Id === this.activeFieldId) || null; }
    // Deliberately NOT toLocaleDateString(): that renders '8/20/2026' for one
    // signer and '20/8/2026' for another on the SAME document, depending on their
    // browser locale. A signed document needs one unambiguous date for everyone.
    get todayDate() {
        const d = new Date();
        const MON = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        return `${String(d.getDate()).padStart(2, '0')} ${MON[d.getMonth()]} ${d.getFullYear()}`;
    }

    get pdfWrapperStyle() {
        // Zoom scales the sheet width; PDFPreview re-renders to the new width
        // via the containerResize postMessage (_postZoomResize).
        const maxW = Math.round(1040 * (this.zoomPct / 100));
        return `position:relative;width:100%;max-width:${maxW}px;height:${this.iframeHeight}px;`;
    }

    /* ── Side rail: zoom + download ── */
    get zoomLabel() { return this.zoomPct + '%'; }

    // Rail appears as soon as the document iframe is up — the consent overlay
    // (z-index 9999) still covers it until the signer agrees.
    get showSideRail() {
        return !!this.iframeUrl;
    }

    handleZoomIn() {
        if (this.zoomPct >= 160) return;
        this.zoomPct += 20;
        this._postZoomResize();
    }

    handleZoomOut() {
        if (this.zoomPct <= 60) return;
        this.zoomPct -= 20;
        this._postZoomResize();
    }

    _postZoomResize() {
        // Wait a frame so the wrapper has its new width, then ask the iframe
        // to re-render at that width (it answers with fresh pagePositions,
        // which re-anchors all field overlays).
        requestAnimationFrame(() => {
            const wrap = this.template.querySelector('.document-wrapper');
            const iframe = this.template.querySelector('.pdf-canvas-host');
            if (wrap && iframe && iframe.contentWindow) {
                try {
                    iframe.contentWindow.postMessage(JSON.stringify({
                        type: 'containerResize',
                        width: wrap.clientWidth
                    }), window.location.origin);
                } catch (e) { /* non-fatal */ }
            }
        });
    }

    handleDownloadDoc() {
        try {
            if (!this._pendingBase64) throw new Error('Document not loaded yet');
            const bin = atob(this._pendingBase64);
            const bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            const blob = new Blob([bytes], { type: 'application/pdf' });
            const a = document.createElement('a');
            a.href = URL.createObjectURL(blob);
            a.download = (this.internalAgreementName || 'document') + '.pdf';
            a.click();
            setTimeout(() => URL.revokeObjectURL(a.href), 10000);
        } catch (e) {
            this.showToast('Download unavailable', 'The document is still loading - try again in a moment.', 'warning');
        }
    }

    get completionStatus() {
        if (!this.signerFields || this.signerFields.length === 0) return '0 / 0 completed';
        const req = this.signerFields.filter(f => f && f.Is_Required__c).length;
        const done = this.signerFields.filter(f => f && f.Is_Required__c && f.Is_Completed__c).length;
        return done + ' / ' + req + ' completed';
    }

    get isCompleteDisabled() {
        if (!this.signerFields || this.signerFields.length === 0) return true;
        const req = this.signerFields.filter(f => f && f.Is_Required__c).length;
        const done = this.signerFields.filter(f => f && f.Is_Required__c && f.Is_Completed__c).length;
        return req > 0 && done < req;
    }

    get isSignatureField() {
        const f = this.activeField;
        return f && (f.Field_Type__c === 'Signature' || f.Field_Type__c === 'Initial');
    }
    get isTextField() {
        const f = this.activeField;
        return f && ['Full Name', 'Email', 'Company', 'Title', 'Text Box'].includes(f.Field_Type__c);
    }
    get isCheckboxField() { return this.activeField && this.activeField.Field_Type__c === 'Checkbox'; }
    get isDateField() { return this.activeField && this.activeField.Field_Type__c === 'Date Signed'; }
    get isActiveFieldRequired() { return !!(this.activeField && this.activeField.Is_Required__c); }

    // "Apply to all" checkbox shows only for Signature/Initial when the signer
    // has more than one field of that same type (otherwise it's pointless).
    get showApplyToAll() {
        const f = this.activeField;
        if (!f || (f.Field_Type__c !== 'Signature' && f.Field_Type__c !== 'Initial')) return false;
        return this.signerFields.filter(x => x && x.Field_Type__c === f.Field_Type__c).length > 1;
    }
    get applyToAllLabel() {
        const t = this.activeField && this.activeField.Field_Type__c === 'Initial' ? 'initial' : 'signature';
        return 'Apply to all my ' + t + ' fields';
    }

    // ── "Next field" navigation (across pages) ──
    // Document-order list of THIS signer's incomplete fields (required first),
    // sorted by page then vertical position so "Next" walks top-to-bottom.
    get _incompleteFieldsInOrder() {
        return (this.signerFields || [])
            .filter(f => f && !f.Is_Completed__c)
            .slice()
            .sort((a, b) => {
                const pa = Number(a.Page_Number__c) || 1, pb = Number(b.Page_Number__c) || 1;
                if (pa !== pb) return pa - pb;
                return (Number(a.Y_Position__c) || 0) - (Number(b.Y_Position__c) || 0);
            });
    }
    get hasNextField() { return this._incompleteFieldsInOrder.length > 0; }
    get nextFieldLabel() {
        const n = this._incompleteFieldsInOrder.length;
        return n > 1 ? ('Next field (' + n + ' left)') : 'Go to field';
    }

    get activeFieldPlaceholder() {
        const map = {
            'Full Name': 'Enter your full name',
            'Email': 'Enter your email',
            'Company': 'Enter company name',
            'Title': 'Enter your title',
            'Text Box': 'Enter text'
        };
        return this.activeField ? (map[this.activeField.Field_Type__c] || 'Enter value') : '';
    }

    get drawTabClass() { return this.showDraw ? 'sig-tab-active' : 'sig-tab'; }
    get typeTabClass() { return this.showType ? 'sig-tab-active' : 'sig-tab'; }
    get uploadTabClass() { return this.showUpload ? 'sig-tab-active' : 'sig-tab'; }

    // SELECT STYLE tab: single big preview that cycles through fonts via
    // "Change Style". DocuSign-style — one style shown at a time.
    get hasTypedName() { return this.typedName && this.typedName.trim().length > 0; }

    get selectedFontStyle() {
        // selectedFont can arrive from a previously saved signature (server
        // data, see loadSavedSignature) as well as the dropdown, so it isn't
        // guaranteed to be one of fontList's values — allowlist before it
        // reaches the style string.
        const font = safeSignatureFont(this.selectedFont || SIGNATURE_FONTS[0]);
        return `font-family:'${font}', cursive; font-size:34px; margin:0; color:#1a1a1a;`;
    }

    get topBarStyle() { return 'background:' + this.brandPrimaryColor + ';'; }
    get brandNameStyle() { return 'color:' + this.brandAccentColor + ';'; }
    get brandNameDisplay() { return this.brandName || 'eSignforce'; }
    get hasBrandLogo() { return this.brandLogoUrl && this.brandLogoUrl.length > 0; }

    /* ── Lifecycle ── */

    connectedCallback() {
        console.log('SVLOG: connectedCallback START, href=', window.location.href);
        // Typed-signature fonts, loaded from this package's own static resource
        // instead of fonts.googleapis.com - a packaged app must not pull styling
        // from a third-party host. loadStyle replaces the hand-built <link>,
        // which is the supported way to bring in a static-resource stylesheet.
        // Every font-family declaration keeps its 'cursive' fallback, so a load
        // failure degrades the lettering rather than blocking signing.
        loadStyle(this, SIGNATURE_FONTS_URL + '/fonts.css').catch(() => {
            // Non-fatal by design - see the fallback note above.
        });

        // Re-render PDF pages at the new width on window resize (debounced; no
        // re-download — uses the cached pdf document).
        this.handleResize = () => {
            clearTimeout(this._resizeTimer);
            this._resizeTimer = setTimeout(() => {
                const host = this.template.querySelector('.pdf-canvas-host');
                // Serialize through the same flag as the initial render so two
                // paintPages() can never run concurrently (would corrupt the
                // canvases and pagePositions). Only repaint after the first
                // render has fully completed.
                if (host && this._pdfDoc && this._pdfRendered && !this._pdfRendering) {
                    this._pdfRendering = true;
                    this.paintPages(host)
                        .catch((e) => { console.warn('SVLOG: resize repaint failed:', e && (e.message || e)); })
                        .finally(() => { this._pdfRendering = false; });
                }
            }, 200);
        };
        window.addEventListener('resize', this.handleResize);

        // The PDFPreview iframe (real pdf.js worker — no main-thread freeze) posts
        // back page positions once it has rendered; use them to place the field
        // overlays, exactly like the internal editor does.
        this._boundPageMsg = (e) => {
            // Accept only OUR canvas frame. On the site it is same-origin, but in
            // Lightning the /apex frame lives on the Visualforce domain — so match
            // by source (tighter than any origin check: no other window
            // qualifies), with same-origin kept as the site-side fallback.
            const canvasFrame = this.template.querySelector('.pdf-canvas-host');
            const fromCanvas = canvasFrame && e.source === canvasFrame.contentWindow;
            if (!fromCanvas && e.origin !== window.location.origin) return;
            let data = e.data;
            if (typeof data === 'string') { try { data = JSON.parse(data); } catch (err) { return; } }
            if (data && data.type === 'pagePositions' && Array.isArray(data.pages)) {
                this.pagePositions = data.pages;
                const last = data.pages[data.pages.length - 1];
                if (last) this.iframeHeight = Math.ceil(Number(last.top || 0) + Number(last.height || 0) + 44);
                this.updateFieldPositions();
                this.updateOtherFieldPositions();
                this._pdfRendered = true;
                this._clearIframeWatchdog();
                console.log('SVLOG: iframe pagePositions received, pages=', data.pages.length);
            }
        };
        window.addEventListener('message', this._boundPageMsg);

        // Token can arrive 3 ways: @api property (Experience Builder binding),
        // CurrentPageReference state (the reliable LWR source), or the URL query
        // string (classic fallback). Don't decide "invalid" here — the page-ref
        // wire may deliver the token AFTER connectedCallback fires.
        this.tryBootstrap();
    }

    // CurrentPageReference is the supported way to read URL query params on LWR
    // Experience sites, where window.location.href often does NOT expose them
    // (this is why a valid /sign/signature?token=... link showed "Invalid signing
    // link" on a subscriber's Enhanced site).
    @wire(CurrentPageReference)
    wiredPageRef(ref) {
        if (ref && ref.state) {
            this._pageRefToken = ref.state.token || ref.state.c__token || this._pageRefToken;
            // In-person flow: this tab was opened from the record page and should
            // hand control back (notify + close) once the signature lands.
            if (ref.state.inperson === '1' || ref.state.c__inperson === '1') {
                this._inPerson = true;
            }
        }
        this._pageRefArrived = true;
        this.tryBootstrap();
    }

    tryBootstrap() {
        if (this._bootstrapped) return;
        let tok = this.token || this._pageRefToken;
        if (!tok) {
            try { tok = new URL(window.location.href).searchParams.get('token'); } catch (e) { /* ignore */ }
        }
        try {
            const q = new URL(window.location.href).searchParams;
            if (q.get('inperson') === '1' || q.get('c__inperson') === '1') this._inPerson = true;
        } catch (e) { /* ignore */ }
        // The token arrives from the URL, so it is attacker-typable. Tokens are
        // minted server-side from [A-Za-z0-9] only — reduce to that alphabet at
        // the source, which also unpoisons every downstream flow that carries it.
        if (tok) tok = String(tok).replace(/[^A-Za-z0-9._-]/g, '');
        if (tok) {
            this._bootstrapped = true;
            this.token = tok;
            console.log('SVLOG: token resolved → bootstrapping');
            this.bootstrapSession(tok);
            return;
        }
        // Only declare "invalid" once the page-ref wire has resolved with no token
        // from ANY source — avoids a false error before the wire fires.
        if (this._pageRefArrived) {
            console.warn('SVLOG: no token from any source → Invalid signing link');
            this.errorMessage = 'Invalid signing link.';
            this.hasError = true;
            this.isLoading = false;
        }
    }

    // Render the PDF once the document area is in the DOM (it is unmounted
    // during bootstrap while isLoading is true).
    renderedCallback() {
        // Focus the code input the first render the OTP gate is up, so a
        // keyboard user can type the code straight from the inbox.
        if (this.showOtpGate && !this._otpFocused) {
            const inp = this.template.querySelector('.otp-input');
            if (inp) { inp.focus(); this._otpFocused = true; }
        }
        this.maybeRenderPdf();
    }

    disconnectedCallback() {
        if (this.handleResize) window.removeEventListener('resize', this.handleResize);
        if (this._boundPageMsg) window.removeEventListener('message', this._boundPageMsg);
        clearTimeout(this._resizeTimer);
        clearInterval(this._otpCooldownTimer);
        this._clearIframeWatchdog();
    }

    /* ── Session binding (strict single-tab; see SignForceSessionService) ── */

    /**
     * Page load does NOT claim the binding — see SignForceSessionService's class
     * header. It only loads what the consent card needs to name the document.
     * The claim happens on the signer's Continue click, so email link scanners,
     * which open the page but never consent, cannot consume it.
     *
     * A browser that already holds the binding (refresh, or reopening the link
     * from the same inbox) skips straight through to the document.
     */
    async bootstrapSession(tok) {
        console.log('SVLOG: bootstrapSession START');
        const held = await this.reuseStoredSession(tok);
        console.log('SVLOG: existing session held?', held);

        await this.loadSignerHeader(tok);
        if (this.hasError) { this.isLoading = false; return; }

        // Email verification gate: sits between the session decision and any
        // document content. Verification is bound to THIS browser tab, not to the
        // permanent server flag — that flag is shared across tabs (and the session
        // itself lives in localStorage, which every tab of the browser shares), so
        // trusting it let a second tab or window open without re-verifying. A
        // per-tab proof in sessionStorage forces each new tab/window to enter the
        // emailed code again, while a refresh of the same tab stays verified.
        // (An already-signed token never reaches this point.)
        //
        // In-person sessions skip the gate — but only when the SERVER also says
        // verified: startInPersonSigning pre-clears OTP_Verified__c because the
        // host checks identity face to face, and it mints a fresh token for this
        // very tab, so the second-tab replay the per-tab proof defends against
        // does not arise. A bare inperson=1 pasted onto a remote link changes
        // nothing: that signer's server flag is still false.
        const inPersonVerified = this._inPerson && this.otpVerified === true;
        if (!this._tabHasOtp(tok) && !this.isSigned && !inPersonVerified) {
            this.showOtpGate = true;
            this._otpPayloadDeferred = held;
            this.isLoading = false;
            this.sendOtp(true);   // auto-send once on gate mount
            return;
        }

        if (held) await this.loadSigningPayload();
        this.isLoading = false;
    }

    /** True when THIS browser already owns the binding. Never claims a new one. */
    async reuseStoredSession(tok) {
        const key = 'sf_session_' + tok;
        let stored = null;
        try { stored = window.localStorage.getItem(key); } catch (e) { /* storage blocked */ }
        if (!stored) return false;

        try {
            const valid = await validateSigningSession({ token: tok, sessionToken: stored });
            if (valid) { this.sessionToken = stored; return true; }
        } catch (e) {
            console.error('SVLOG: validateSigningSession exception:', e);
        }
        // Stale — e.g. the link was resent, which clears the binding server-side.
        try { window.localStorage.removeItem(key); } catch (e) { /* ignore */ }
        return false;
    }

    /**
     * Claims the link for this browser. False means someone else got there
     * first, and this browser must not be allowed in.
     */
    async claimSession(tok) {
        try {
            const newToken = await startSigningSession({ token: tok });
            if (newToken) {
                try { window.localStorage.setItem('sf_session_' + tok, newToken); } catch (e) { /* ignore */ }
                this.sessionToken = newToken;
                return true;
            }
            console.warn('SVLOG: link already bound to another browser');
        } catch (e) {
            console.error('SVLOG: startSigningSession exception:', e);
        }
        return false;
    }

    /* ── Data Loading ── */

    /**
     * Everything the consent card needs, and nothing that needs a bound session:
     * who the signer is, what the document is called, and the branding. Safe to
     * run before the binding is claimed.
     */
    async loadSignerHeader(tok) {
        console.log('SVLOG: loadSignerHeader START');
        try {
            const result = await getSignerByToken({ token: tok });
            console.log('SVLOG: getSignerByToken result=', JSON.stringify(result));
            if (result.error) {
                console.error('SVLOG: signer result.error=', result.error);
                // Inline strips on every server-sourced value that reaches the
                // template: the scanner does not trace helper functions, so each
                // sanitiser sits directly on the assignment into the tracked prop.
                this.errorMessage = String(result.error || '').replace(/[<>&`]/g, '');
                this.hasError = true;
            } else {
                this.internalSignerId = result.signerId;
                this.internalAgreementName = result.agreementName;
                this.internalSignerEmail = String(result.signerEmail || '').replace(/[<>&"'`]/g, '');
                this.internalSignerName = String(result.signerName || '').replace(/[<>&`]/g, '');
                // Seed the typed-signature defaults up front from the signer's
                // record name so the adopt sheet shows their name + initials on
                // first open (no manual typing). loadSavedSignature() below runs
                // later in Promise.all and still overrides typedName when a
                // previously saved "Type" signature exists, so precedence holds.
                if (!this.typedName && this.internalSignerName) {
                    this.typedName = String(this.internalSignerName || '').replace(/[<>&`]/g, '');
                    this.typedInitials = this.deriveInitials(this.internalSignerName);
                    this.selectedFont = this.fontList[0];
                }
                this.internalAgreementId = result.agreementId;
                this.envelopeId = String(result.envelopeId || '').replace(/[^A-Za-z0-9-]/g, '');
                // A signer who verified earlier (e.g. refreshed the page) must
                // not be asked for a fresh code.
                this.otpVerified = result.otpVerified === true;

                // Branding is public; fetch in parallel and best-effort.
                try {
                    const brand = await getBranding();
                    if (brand) {
                        this.brandName = brand.companyName || 'eSignforce';
                        this.brandPrimaryColor =  /^#[0-9a-fA-F]{3,8}$/.test(brand.primaryColor) ? brand.primaryColor : '#0a1628';
                        this.brandAccentColor = /^#[0-9a-fA-F]{3,8}$/.test(brand.accentColor) ? brand.accentColor : '#f59e0b';
                        this.brandLogoUrl = safeImageSrc(brand.logoUrl || '');
                    }
                } catch (e) { /* keep defaults */ }

                console.log('SVLOG: header loaded, agreement=', this.internalAgreementName, 'envelope=', this.envelopeId);
            }
        } catch (e) {
            this.errorMessage = 'Failed to load. Please try again.';
            this.hasError = true;
        }
    }

    /**
     * The document itself and everything drawn on it. Every call in here is
     * session-gated server-side, so this must run only once the binding is held.
     */
    async loadSigningPayload() {
        console.log('SVLOG: loadSigningPayload START');
        try {
            await Promise.all([
                this.loadDocument(),
                this.loadFields(),
                this.loadOtherFields(),
                this.loadSavedSignature()
            ]);
            console.log('SVLOG: payload DONE. signerFields=', this.signerFields.length, 'pagePositions=', this.pagePositions.length);
        } catch (e) {
            this.errorMessage = 'Failed to load. Please try again.';
            this.hasError = true;
        }
    }

    // Load pdf.js (static resource) once and point its worker at the packaged
    // worker resource. Namespace-safe via @salesforce/resourceUrl.
    async ensurePdfLib() {
        if (!this._pdfLibPromise) {
            this._installStructuredCloneShim();
            this._installFontFetchShim();
            this._pdfLibPromise = Promise.all([
                loadScript(this, PDFJS_LIB),
                // Standard fonts as base64 → window.__sfPdfFontData (the fetch
                // shim serves these to pdf.js; LWS blocks fetching them by URL).
                loadScript(this, PDFJS_FONTS_DATA)
            ]).then(() => {
                if (window.pdfjsLib && window.pdfjsLib.GlobalWorkerOptions) {
                    try {
                        // Prefer a REAL worker (off-thread parse/render) so large
                        // PDFs don't freeze the main thread. Using workerPort with a
                        // direct Worker avoids the blob: URL that the guest LWR CSP
                        // blocks. If new Worker() is blocked, fall back to the
                        // main-thread "fake worker" (previous behaviour).
                        const w = new Worker(PDFJS_WORKER);
                        window.pdfjsLib.GlobalWorkerOptions.workerPort = w;
                        console.log('SVLOG: real pdf.js worker enabled');
                    } catch (e) {
                        console.warn('SVLOG: real worker blocked, using fake worker:', e && (e.message || e));
                        window.pdfjsLib.GlobalWorkerOptions.workerSrc = PDFJS_WORKER;
                    }
                }
            });
        }
        return this._pdfLibPromise;
    }

    // pdf.js v3's LoopbackPort (its main-thread "fake worker" — used because the
    // real worker's blob URL is CSP-blocked on guest LWR sites) calls the native
    // structuredClone, which throws DataCloneError under Lightning Web Security
    // (sandboxed proxy objects aren't structured-cloneable). Wrap structuredClone
    // so it falls back to a manual deep clone whenever the native call fails.
    _installStructuredCloneShim() {
        if (window.__sfStructuredCloneShim) return;
        const native = window.structuredClone;
        const manual = (input) => {
            const seen = new WeakMap();
            const clone = (val) => {
                if (val === null || typeof val !== 'object') return val;
                if (seen.has(val)) return seen.get(val);
                if (val instanceof ArrayBuffer) return val.slice(0);
                if (ArrayBuffer.isView(val)) {
                    return new val.constructor(val.buffer.slice(0), val.byteOffset, val.length);
                }
                if (Array.isArray(val)) {
                    const arr = []; seen.set(val, arr);
                    for (let i = 0; i < val.length; i++) arr[i] = clone(val[i]);
                    return arr;
                }
                if (val instanceof Map) {
                    const m = new Map(); seen.set(val, m);
                    val.forEach((v, k) => m.set(clone(k), clone(v)));
                    return m;
                }
                if (val instanceof Set) {
                    const s = new Set(); seen.set(val, s);
                    val.forEach((v) => s.add(clone(v)));
                    return s;
                }
                if (val instanceof Date) return new Date(val.getTime());
                const out = {}; seen.set(val, out);
                for (const k in val) {
                    if (Object.prototype.hasOwnProperty.call(val, k)) out[k] = clone(val[k]);
                }
                return out;
            };
            return clone(input);
        };
        window.structuredClone = function (input, options) {
            if (native) {
                try { return native.call(window, input, options); } catch (e) { /* LWS → manual */ }
            }
            return manual(input);
        };
        window.__sfStructuredCloneShim = true;
    }

    // pdf.js fetches its standard-font files (FoxitSans.pfb …) by URL, but the
    // guest Experience site's Lightning Web Security blocks that request
    // ("Cannot request disallowed endpoint"), so non-embedded Helvetica/Times
    // text disappears. We preload the fonts as base64 (window.__sfPdfFontData,
    // via loadScript) and intercept fetch() for any *.pfb we hold, returning the
    // bytes directly — no network request, so LWS never blocks it.
    _installFontFetchShim() {
        if (window.__sfFontFetchShim) return;
        const origFetch = (typeof window.fetch === 'function') ? window.fetch.bind(window) : null;
        const toBytes = (b64) => {
            const bin = atob(b64);
            const a = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i);
            return a;
        };
        window.fetch = function (input, init) {
            try {
                const url = (typeof input === 'string') ? input : (input && input.url) || '';
                const m = url.match(/([A-Za-z0-9_-]+\.pfb)(?:[?#]|$)/);
                if (m && window.__sfPdfFontData && window.__sfPdfFontData[m[1]]) {
                    return Promise.resolve(new Response(toBytes(window.__sfPdfFontData[m[1]]), {
                        status: 200,
                        headers: { 'Content-Type': 'application/octet-stream' }
                    }));
                }
            } catch (e) { /* fall through to native fetch */ }
            return origFetch ? origFetch(input, init) : Promise.reject(new Error('fetch unavailable'));
        };
        window.__sfFontFetchShim = true;
    }

    // Render only when (a) the source is resolved and (b) the canvas host is in
    // the DOM. Called from renderedCallback (retries until the host exists).
    maybeRenderPdf() {
        if (this._pdfRendered || this._pdfRendering || this._pdfFailed) return;
        if (!this._pdfSource) return;
        // The in-page div is the always-present host; the iframe only exists
        // once a site render sets iframeUrl.
        const host = this.template.querySelector('.pdf-inpage-host')
            || this.template.querySelector('.pdf-canvas-host');
        if (!host) return;
        this._pdfRendering = true;
        this.renderResolvedSource(host)
            .then(() => { this._pdfRendered = true; })
            .catch((e) => {
                // Terminal failure: mark failed so renderedCallback doesn't retry
                // forever, and surface an error instead of an invisible blank box.
                this._pdfFailed = true;
                console.error('SVLOG: PDF render failed:', e && (e.message || e));
                this.errorMessage = 'Could not load the document. Please ask the sender to resend the link.';
                this.hasError = true;
            })
            .finally(() => { this._pdfRendering = false; });
    }

    async _fetchCloudBase64() {
        const CHUNK = 1200000; // multiple of 3
        const first = await getCloudDocChunk({
            token: this.token, sessionToken: this.sessionToken, rangeStart: 0, rangeLen: CHUNK
        });
        if (!first || !first.base64) return '';
        const size = Number(first.size) || 0;
        // Older Lambda ignores the range and returns the whole file — use it as-is
        // rather than fetching duplicate full copies (which froze the page).
        if (Math.floor(first.base64.length * 3 / 4) >= size) return first.base64;
        const parts = [first.base64];
        const jobs = [];
        for (let off = CHUNK; off < size; off += CHUNK) {
            const at = off;
            jobs.push(getCloudDocChunk({
                token: this.token, sessionToken: this.sessionToken, rangeStart: at, rangeLen: CHUNK
            }).then(r => ({ at, b64: (r && r.base64) || '' })));
        }
        const rest = (await Promise.all(jobs)).sort((a, b) => a.at - b.at);
        for (const r of rest) parts.push(r.b64);
        return parts.join('');
    }

    /** Render the resolved PDF bytes in a PDFPreview iframe (real worker, off-thread). */
    _renderViaIframe(b64) {
        this._pendingBase64 = b64;
        this._armIframeWatchdog(b64);
        // Context decides the frame URL. On the guest LWR Experience site a plain
        // /apex/ URL resolves to the site (→ "Invalid signing link" inside the
        // frame): VF pages are served under /sfsites/c/apex/ there. Inside
        // Lightning (the in-person tab) that site path does not exist — its
        // bounce to /lightning/404 framebusts the whole signing session away —
        // and the plain /apex/ frame is the one documentEditor already uses.
        // The frame is CROSS-origin in Lightning (VF domain), so the byte
        // hand-off must not pin targetOrigin to this window's origin there.
        const isLightning = window.location.pathname.indexOf('/lightning/') === 0;
        this._frameTargetOrigin = isLightning ? '*' : window.location.origin;
        const vfBase = isLightning ? vfPageUrl('PDFPreview') : '/sfsites/c' + vfPageUrl('PDFPreview');
        this.iframeUrl = vfBase + '?mode=receive&bg=light&ts=' + Date.now();
        console.log('SVLOG: rendering via iframe, url=', this.iframeUrl, 'bytes len=', b64 && b64.length);
    }

    /**
     * pdf.js options that survive a locked-down Experience site. Shared by the
     * iframe path and the in-page fallback so both render identically.
     *  - isEvalSupported:false  → never eval() (site CSP blocks 'unsafe-eval';
     *    with eval blocked pdf.js silently paints a BLANK canvas).
     *  - disableFontFace:true   → draw glyph outlines instead of @font-face blobs
     *    (font-src blob: is usually blocked).
     *  - disableStream/disableRange:true → one request, no byte-range fetches.
     */
    _cspOpts() {
        return {
            isEvalSupported: false,
            disableFontFace: true,
            disableStream: true,
            disableRange: true,
            standardFontDataUrl: PDFJS_STD_FONTS + '/'
        };
    }

    /**
     * The iframe renders in a Visualforce page, and an LWR Experience site serves
     * that page under a strict CSP that blocks its inline script. When that
     * happens nothing throws - the frame just never posts back pagePositions and
     * the signer stares at an empty box. So give it a deadline, and if it misses,
     * render the same bytes in this component instead. Slower (main-thread pdf.js)
     * but it is the path that worked before the iframe existed.
     */
    _armIframeWatchdog(b64) {
        this._clearIframeWatchdog();
        this._iframeWatchdog = setTimeout(() => {
            if (this._pdfRendered) return;
            console.warn('SVLOG: iframe did not report back in time - falling back to in-page render');
            this._renderInPage(b64);
        }, 9000);
    }

    _clearIframeWatchdog() {
        if (this._iframeWatchdog) { clearTimeout(this._iframeWatchdog); this._iframeWatchdog = null; }
    }

    /** base64 → Uint8Array, so pdf.js parses bytes already in memory. */
    _b64ToBytes(b64) {
        const bin = atob(b64);
        const out = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
        return out;
    }

    /** Fallback render: pdf.js inside this component, no iframe, no VF page. */
    async _renderInPage(b64) {
        // Lightning runs under Lightning Web Security, which freezes `fetch` on
        // the module scope — pdf.js's worker setup tries to reassign it and
        // throws "Cannot assign to read only property 'fetch'". In-page pdf.js
        // simply cannot run here, so never attempt it in Lightning: keep the
        // iframe as the only Lightning render path and fail with the normal
        // "could not load" card instead of a confusing LWS crash.
        if (window.location.pathname.indexOf('/lightning/') === 0) {
            console.warn('SVLOG: in-page render skipped in Lightning (LWS blocks pdf.js worker); iframe is the only path here');
            return;
        }
        // The dedicated div, never the iframe: children appended inside an
        // <iframe> element are fallback content the browser never paints.
        const host = this.template.querySelector('.pdf-inpage-host')
            || this._renderHost
            || this.template.querySelector('.pdf-canvas-host');
        if (!host || !b64) return;
        try {
            await this.ensurePdfLib();
            const lib = window.pdfjsLib;
            if (!lib) throw new Error('pdf.js unavailable');
            // Hide the dead frame so the fallback is not painted underneath it.
            this.iframeUrl = '';
            this._pdfDoc = await this._loadPdf(lib, { data: this._b64ToBytes(b64), ...this._cspOpts() });
            await this.paintPages(host);
            this._pdfRendered = true;
            console.log('SVLOG: in-page fallback rendered, pages=', this._pdfDoc.numPages);
        } catch (e) {
            this._pdfFailed = true;
            console.error('SVLOG: in-page fallback failed:', e && (e.message || e));
            this.errorMessage = 'Could not load the document. Please ask the sender to resend the link.';
            this.hasError = true;
        }
    }

    /** Once the PDFPreview iframe has loaded, hand it the PDF bytes. */
    handleFrameLoad(event) {
        if (!this._pendingBase64) return;

        // The frame is same-origin (both on the site domain), so we can look
        // inside it. An LWR site does not serve Visualforce under /sfsites/c/apex/
        // and hands back its own "site is temporarily unavailable" page instead -
        // which loads fine, so onload alone proves nothing. Check for a marker the
        // real PDFPreview page always has, and if it is missing fall back at once
        // rather than making every signer sit through the watchdog timeout.
        try {
            const doc = event.target.contentDocument;
            if (doc && !doc.getElementById('pages')) {
                console.warn('SVLOG: iframe did not load PDFPreview (site error page) - falling back now');
                this._clearIframeWatchdog();
                this._renderInPage(this._pendingBase64);
                return;
            }
        } catch (e) {
            // Cross-origin after all: cannot inspect, so leave it to the watchdog.
        }

        try {
            event.target.contentWindow.postMessage(JSON.stringify({
                type: 'loadPdfBase64', data: this._pendingBase64
            }), this._frameTargetOrigin || window.location.origin);
        } catch (e) { console.warn('SVLOG: frame post failed:', e && (e.message || e)); }
    }

    async renderResolvedSource(host) {
        this._renderHost = host;
        await this.ensurePdfLib();
        const lib = window.pdfjsLib;
        const url = this._pdfSource && this._pdfSource.url;
        console.log('SVLOG: renderResolvedSource start, url?', !!url, 'lib?', !!lib);

        // CSP-safe pdf.js options for locked-down Experience sites:
        //  - isEvalSupported:false  → never use eval()/new Function() (Experience
        //    site CSP blocks 'unsafe-eval'; with eval blocked, pdf.js silently
        //    paints a BLANK canvas).
        //  - disableFontFace:true   → draw glyph outlines on canvas instead of
        //    injecting @font-face blob fonts (site CSP usually blocks font-src blob:).
        //  - disableStream/disableRange:true → fetch the whole doc in one request
        //    (no S3 byte-range requests, which CORS/CSP would block).
        const CSP_OPTS = this._cspOpts();

        // ── PROXY-FIRST (reliable on locked-down Experience sites) ──
        // A guest signing portal ALWAYS runs on the CSP-locked Experience site,
        // where pdf.js cannot fetch S3 directly: connect-src blocks the cross-origin
        // request and the main-thread "fake worker" HANGS on it (no resolve/reject).
        // So we pull the bytes through the same-origin Apex proxy and let pdf.js
        // parse them IN MEMORY — no network fetch inside pdf.js → no hang.
        let cvId = null;
        try { cvId = await getDocumentVersion({ token: this.token }); } catch (e) { /* ignore */ }
        console.log('SVLOG: proxy-first cvId=', cvId);
        if (cvId) {
            try {
                const base64 = await proxyPdfViaLambda({
                    token: this.token, sessionToken: this.sessionToken, contentVersionId: cvId
                });
                console.log('SVLOG: proxy bytes len=', base64 && base64.length);
                if (base64) {
                    this._renderViaIframe(base64);
                    return;
                }
            } catch (e) {
                console.warn('SVLOG: CV proxy render failed → next path:', e && (e.message || e));
            }
        }

        // ── S3-ONLY docs (no Salesforce ContentVersion) ──
        // Lambda fetches the presigned S3 URL server-side (it has the AWS keys)
        // and returns the bytes; the browser never touches S3, so the CSP block /
        // fake-worker hang on a direct S3 fetch is avoided.
        if (!cvId) {
            try {
                const s3b64 = await proxyS3Pdf({ token: this.token, sessionToken: this.sessionToken });
                console.log('SVLOG: s3-proxy bytes len=', s3b64 && s3b64.length);
                if (s3b64) {
                    this._renderViaIframe(s3b64);
                    return;
                }
            } catch (e) {
                console.warn('SVLOG: S3 proxy render failed → trying direct S3 URL:', e && (e.message || e));
            }
        }

        // ── Cloud (Google Drive / OneDrive) docs — fetch bytes in ranges ──
        if (!cvId) {
            try {
                const cloudB64 = await this._fetchCloudBase64();
                console.log('SVLOG: cloud bytes len=', cloudB64 && cloudB64.length);
                if (cloudB64) {
                    this._renderViaIframe(cloudB64);
                    return;
                }
            } catch (e) {
                console.warn('SVLOG: cloud render failed:', e && (e.message || e));
            }
        }

        // ── LAST RESORT: direct presigned S3 URL ──
        // Only reached for oversized docs / when both proxies returned nothing.
        // Needs the site CSP connect-src + S3 bucket CORS; otherwise the _loadPdf
        // timeout fires and surfaces a clean error (no silent hang).
        if (url) {
            this._pdfDoc = await this._loadPdf(lib, { url, ...CSP_OPTS });
            console.log('SVLOG: direct getDocument OK numPages=', this._pdfDoc.numPages);
            await this.paintPages(host);
            return;
        }

        throw new Error('No document available to render');
    }

    /**
     * getDocument() that can never hang forever. Races the load against a timer
     * and destroys the loading task on timeout, so a stuck fake-worker fetch turns
     * into a clean rejection (visible error) instead of a silent blank page.
     */
    _loadPdf(lib, params, ms = 15000) {
        const task = lib.getDocument(params);
        // Swallow any late rejection after the race has already settled via timeout.
        task.promise.catch(() => { /* handled by the race below */ });
        let timer;
        const timeout = new Promise((resolve, reject) => {
            timer = setTimeout(() => {
                try {
                    const d = task.destroy();
                    if (d && typeof d.catch === 'function') d.catch(() => { /* ignore */ });
                } catch (e) { /* ignore */ }
                reject(new Error('PDF load timed out (' + ms + 'ms)'));
            }, ms);
        });
        return Promise.race([task.promise, timeout]).finally(() => clearTimeout(timer));
    }

    /**
     * Races any promise against a timer so a stuck LWS fake-worker step (getPage /
     * page.render parsing on the main thread) turns into a clean rejection instead
     * of a silent, permanent blank document.
     */
    _withTimeout(promise, ms, label) {
        let timer;
        const timeout = new Promise((resolve, reject) => {
            timer = setTimeout(() => reject(new Error(label + ' timed out (' + ms + 'ms)')), ms);
        });
        return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
    }

    _base64ToBytes(b64) {
        const bin = atob(b64);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        return bytes;
    }

    async paintPages(host) {
        if (!this._pdfDoc || !window.pdfjsLib) return;

        // Clear any previous canvases (resize re-render).
        while (host.firstChild) host.removeChild(host.firstChild);

        const rect = host.getBoundingClientRect();
        const containerWidth = (rect && rect.width) ? rect.width : REFERENCE_PAGE_WIDTH;
        console.log('SVLOG: paintPages START containerWidth=', containerWidth, 'numPages=', this._pdfDoc.numPages);
        // Guest LWR sites can't use pdf.js's real worker, so rendering is on the
        // main thread. Cap the device-pixel-ratio to keep the rasterization cheap
        // (a large multi-page PDF at retina DPR froze the tab).
        const dpr = 1;
        // Visible gap between page "sheets". The wrapper is transparent and each
        // canvas is a white sheet, so this gap shows the slate-50 page area and
        // makes a page boundary obvious (instead of a blank band on one card).
        const GAP = 28;

        const positions = [];
        let cursorTop = 0;

        for (let n = 1; n <= this._pdfDoc.numPages; n++) {
            // eslint-disable-next-line no-await-in-loop
            const page = await this._withTimeout(this._pdfDoc.getPage(n), 15000, 'getPage ' + n);
            const base = page.getViewport({ scale: 1 });
            const scale = containerWidth / base.width;
            const viewport = page.getViewport({ scale });

            const canvas = document.createElement('canvas');
            canvas.width = Math.floor(viewport.width * dpr);
            canvas.height = Math.floor(viewport.height * dpr);
            canvas.style.width = viewport.width + 'px';
            canvas.style.height = viewport.height + 'px';
            canvas.style.display = 'block';
            canvas.style.marginBottom = GAP + 'px';
            host.appendChild(canvas);

            const ctx = canvas.getContext('2d');
            ctx.scale(dpr, dpr);
            const renderTask = page.render({ canvasContext: ctx, viewport });
            // Swallow a late rejection if the timeout already won the race.
            renderTask.promise.catch(() => { /* handled by the race below */ });
            try {
                // eslint-disable-next-line no-await-in-loop
                await this._withTimeout(renderTask.promise, 30000, 'render ' + n);
            } catch (e) {
                try { renderTask.cancel(); } catch (err) { /* ignore */ }
                throw e;
            }
            console.log('SVLOG: page', n, 'rendered', Math.round(viewport.width), 'x', Math.round(viewport.height), 'canvasW=', canvas.width);

            // Same {top,left,width,height} shape the VF page used to postMessage,
            // so updateFieldPositions()/updateOtherFieldPositions() are unchanged.
            positions.push({ top: cursorTop, left: 0, width: viewport.width, height: viewport.height });
            cursorTop += viewport.height + GAP;

            // Guest LWR sites can't use pdf.js's real worker, so rendering runs on
            // the main thread. Yield between pages (and let the first page paint
            // immediately) so a large multi-page doc doesn't freeze the tab.
            this.pagePositions = positions.slice();
            this.updateFieldPositions();
            // eslint-disable-next-line no-await-in-loop
            await new Promise(r => setTimeout(r, 0));
        }

        this.pagePositions = positions;
        this.iframeHeight = cursorTop + 44;
        console.log('SVLOG: paintPages DONE pages=', positions.length, 'iframeHeight=', this.iframeHeight, 'hostChildren=', host.childElementCount);
        this.updateFieldPositions();
        this.updateOtherFieldPositions();
    }

    async loadDocument() {
        // Resolve the PDF SOURCE only — no DOM work here. During bootstrap the
        // document area is unmounted (isLoading is still true), so the actual
        // render is deferred to renderedCallback → maybeRenderPdf().
        console.log('SVLOG: loadDocument START, token?', !!this.token, 'sessionToken?', !!this.sessionToken);
        try {
            const url = await getSigningPdfUrl({ token: this.token, sessionToken: this.sessionToken });
            console.log('SVLOG: getSigningPdfUrl returned=', url ? String(url).slice(0, 80) : null);
            this._pdfSource = { url: url || null };
        } catch (e) {
            console.error('SVLOG: getSigningPdfUrl failed:', e && (e.body ? e.body.message : e.message));
            // Still set a source so renderResolvedSource can try the proxy fallback.
            this._pdfSource = { url: null };
        }
        this.maybeRenderPdf();
    }

    async loadFields() {
        try {
            const fields = stripNs(await getFieldsForSigner({ token: this.token }));
            console.log('SVLOG: getFieldsForSigner count=', fields ? fields.length : 0, 'sample=', JSON.stringify(fields && fields[0]));
            this.signerFields = (fields || []).map(f => ({
                ...f,
                Is_Completed__c: f.Field_Type__c === 'Date Signed' ? true : (f.Is_Completed__c || false),
                // A 'Date Signed' field is auto-filled, but only ONCE. Re-stamping it on
                // every load overwrote the date a previous visit had already stored (and
                // completeSigning saves signerFields verbatim, so the old date was lost).
                Field_Value__c: f.Field_Type__c === 'Date Signed'
                    ? (f.Field_Value__c || this.todayDate)
                    : (f.Field_Value__c || ''),
                displayLabel: f.Field_Label__c,
                fieldClass: f.Is_Completed__c ? 'field-box-completed' : 'field-box',
                fieldStyle: 'display:none;',
                isDrawSignature: false,
                isTypedSignature: false,
                isUploadSignature: false,
                isTextValue: false,
                drawPaths: [],
                typedName: '',
                typedFontStyle: ''
            }));
            if (this.pagePositions && this.pagePositions.length > 0) {
                this.updateFieldPositions();
            }
        } catch (e) { /* swallow - page still usable */ }
    }

    // Read-only layer: completed fields of PREVIOUS signers, so this signer
    // sees every signature already placed on the document.
    async loadOtherFields() {
        try {
            const fields = stripNs(await getOtherCompletedFields({ token: this.token }));
            this.otherFields = (fields || []).map(f => ({ ...f, fieldStyle: 'display:none;' }));
            if (this.pagePositions && this.pagePositions.length > 0) {
                this.updateOtherFieldPositions();
            }
        } catch (e) { /* read-only layer is best-effort */ }
    }

    async loadSavedSignature() {
        try {
            // Note: signature is now keyed to the token's signer's email
            // (verified server-side), not whatever email the client sends.
            const saved = await getSavedSignature({ token: this.token, sessionToken: this.sessionToken });
            if (saved && saved.found && saved.signatureData) {
                if (saved.signatureType === 'Draw') {
                    try {
                        // Stored server-side; rebuild each path with the d attribute
                        // reduced to SVG path grammar before it reaches the template.
                        this.paths = JSON.parse(saved.signatureData).map(p => ({
                            id: p.id,
                            d: String(p.d || '').replace(/[^MmLlHhVvCcSsQqTtAaZz0-9.,\s+-]/g, '')
                        }));
                        this.showDrawPlaceholder = false;
                    } catch (e) { /* ignore */ }
                } else if (saved.signatureType === 'Type') {
                    const parts = saved.signatureData.split(':');
                    this.typedName = String(parts[1] || '').replace(/[<>&`]/g, '');
                    this.selectedFont = String(parts[2] || '').replace(/[^A-Za-z0-9 ]/g, '');
                    // Saved signatures encode name+font but not initials, so
                    // derive them — otherwise the Initials box shows empty next
                    // to a populated Full Name for a returning signer.
                    if (!this.typedInitials && this.typedName) {
                        this.typedInitials = this.deriveInitials(this.typedName);
                    }
                    this.showDraw = false; this.showType = true;
                } else if (saved.signatureType === 'Upload') {
                    this.uploadedImage = saved.signatureData;
                    this.showDraw = false; this.showUpload = true;
                }
            }
        } catch (e) { /* fall through with empty signature state */ }
    }

    /* ── Field positioning (unchanged from prior patch) ── */

    updateFieldPositions() {
        if (!this.pagePositions || this.pagePositions.length === 0) return;
        if (!this.signerFields || this.signerFields.length === 0) return;

        this.signerFields = this.signerFields.map(f => {
            if (!f) return null;

            const pageIndex = (f.Page_Number__c || 1) - 1;
            const pagePos = this.pagePositions[pageIndex];
            if (!pagePos) return f;

            const viewerPageWidth = Number(pagePos.width);
            const editorPageWidth = Number(f.Page_Width__c) || REFERENCE_PAGE_WIDTH;
            const scale = viewerPageWidth / editorPageWidth;

            const absoluteX = Number(pagePos.left || 0) + (Number(f.X_Position__c || 0) * scale);
            const absoluteY = Number(pagePos.top) + (Number(f.Y_Position__c || 0) * scale);
            const fieldWidth = Number(f.Width__c || 150) * scale;
            const fieldHeight = Number(f.Height__c || 50) * scale;

            const completed = f.Is_Completed__c;

            const val = f.Field_Value__c || '';
            let isDrawSignature = false;
            let isTypedSignature = false;
            let isUploadSignature = false;
            let isTextValue = false;
            let drawPaths = [];
            let typedName = '';
            let typedFontStyle = '';

            if (completed && (f.Field_Type__c === 'Signature' || f.Field_Type__c === 'Initial')) {
                if (val.startsWith('[')) {
                    isDrawSignature = true;
                    try {
                        drawPaths = JSON.parse(val).map(p => ({
                            id: p.id,
                            d: String(p.d || '').replace(/[^MmLlHhVvCcSsQqTtAaZz0-9.,\s+-]/g, '')
                        }));
                    } catch (e) { drawPaths = []; }
                } else if (val.startsWith('typed:')) {
                    isTypedSignature = true;
                    const parts = val.split(':');
                    typedName = String(parts[1] || '').replace(/[<>&`]/g, '');
                    // Field_Value__c is signer-supplied and stored server-side;
                    // allowlist the font before it lands in a style attribute.
                    const fontFamily = safeSignatureFont(parts[2]).replace(/[^A-Za-z0-9 ]/g, '');
                    typedFontStyle = `font-family:'${fontFamily}',cursive;`;
                } else if (val.startsWith('data:')) {
                    isUploadSignature = true;
                } else {
                    isTextValue = true;
                }
            } else if (completed) {
                isTextValue = true;
            }

            return {
                ...f,
                fieldClass: completed ? 'field-box-completed' : 'field-box',
                fieldStyle: `left:${Number(absoluteX) || 0}px;top:${Number(absoluteY) || 0}px;width:${Number(fieldWidth) || 0}px;height:${Number(fieldHeight) || 0}px;position:absolute;z-index:10;cursor:pointer;`,
                displayLabel: f.Field_Label__c,
                isDrawSignature,
                isTypedSignature,
                isUploadSignature,
                // Rendered by the template instead of Field_Value__c: the value is
                // signer-supplied and stored server-side, so the scheme is checked
                // before it becomes an img source. isUploadSignature is only set
                // when val already starts with 'data:'.
                uploadImageSrc: (typeof val === 'string' && /^(data:image\/[a-z0-9.+-]+[;,]|https:\/\/|\/(?!\/))/i.test(val.trim())) ? val.trim() : '',
                isTextValue,
                drawPaths,
                typedName,
                typedFontStyle
            };
        }).filter(f => f != null);

        this.updateOtherFieldPositions();
    }

    // Same positioning math as updateFieldPositions, applied to the read-only
    // layer. No click handlers, no progress impact.
    updateOtherFieldPositions() {
        if (!this.pagePositions || this.pagePositions.length === 0) return;
        if (!this.otherFields || this.otherFields.length === 0) return;

        this.otherFields = this.otherFields.map(f => {
            if (!f) return null;

            const pageIndex = (f.Page_Number__c || 1) - 1;
            const pagePos = this.pagePositions[pageIndex];
            if (!pagePos) return f;

            const viewerPageWidth = Number(pagePos.width);
            const editorPageWidth = Number(f.Page_Width__c) || REFERENCE_PAGE_WIDTH;
            const scale = viewerPageWidth / editorPageWidth;

            const absoluteX = Number(pagePos.left || 0) + (Number(f.X_Position__c || 0) * scale);
            const absoluteY = Number(pagePos.top) + (Number(f.Y_Position__c || 0) * scale);
            const fieldWidth = Number(f.Width__c || 150) * scale;
            const fieldHeight = Number(f.Height__c || 50) * scale;

            const val = f.Field_Value__c || '';
            let isDrawSignature = false;
            let isTypedSignature = false;
            let isUploadSignature = false;
            let isTextValue = false;
            let drawPaths = [];
            let typedName = '';
            let typedFontStyle = '';

            if (f.Field_Type__c === 'Signature' || f.Field_Type__c === 'Initial') {
                if (val.startsWith('[')) {
                    isDrawSignature = true;
                    try {
                        drawPaths = JSON.parse(val).map(p => ({
                            id: p.id,
                            d: String(p.d || '').replace(/[^MmLlHhVvCcSsQqTtAaZz0-9.,\s+-]/g, '')
                        }));
                    } catch (e) { drawPaths = []; }
                } else if (val.startsWith('typed:')) {
                    isTypedSignature = true;
                    const parts = val.split(':');
                    typedName = String(parts[1] || '').replace(/[<>&`]/g, '');
                    // This value was written by a DIFFERENT signer and is
                    // rendered into the current signer's page (read-only
                    // "other signers" layer) — allowlist before it reaches
                    // a style attribute.
                    const fontFamily = safeSignatureFont(parts[2]).replace(/[^A-Za-z0-9 ]/g, '');
                    typedFontStyle = `font-family:'${fontFamily}',cursive;`;
                } else if (val.startsWith('data:')) {
                    isUploadSignature = true;
                } else {
                    isTextValue = true;
                }
            } else {
                isTextValue = true;
            }

            return {
                ...f,
                fieldClass: 'field-box-readonly',
                fieldStyle: `left:${Number(absoluteX) || 0}px;top:${Number(absoluteY) || 0}px;width:${Number(fieldWidth) || 0}px;height:${Number(fieldHeight) || 0}px;position:absolute;z-index:9;`,
                isDrawSignature,
                isTypedSignature,
                isUploadSignature,
                // Written by a DIFFERENT signer and rendered into this signer's
                // page, so the same scheme check applies here.
                uploadImageSrc: (typeof val === 'string' && /^(data:image\/[a-z0-9.+-]+[;,]|https:\/\/|\/(?!\/))/i.test(val.trim())) ? val.trim() : '',
                isTextValue,
                drawPaths,
                typedName,
                typedFontStyle
            };
        }).filter(f => f != null);
    }

    /* ── Field click ── */

    handleFieldClick(e) {
        e.stopPropagation();
        const fieldId = e.currentTarget.dataset.id;
        const field = this.signerFields.find(f => f && f.Id === fieldId);
        this.openField(field);
    }

    // Open a field's bottom sheet. Shared by direct click AND the "Next field"
    // navigation button so both behave identically.
    openField(field) {
        if (!field) return;
        this.activeFieldId = field.Id;
        this.fieldInputValue = field.Field_Value__c || '';
        this.checkboxValue = field.Field_Value__c === 'true';
        this.showBottomSheet = true;

        if (field.Field_Type__c === 'Signature' || field.Field_Type__c === 'Initial') {
            // Default to "Select Style" — matches the DocuSign adopt flow.
            this.showDraw = false;
            this.showType = true;
            this.showUpload = false;
            if (!field.Is_Completed__c) {
                this.paths = [];
                this.showDrawPlaceholder = true;
            }
            // Pre-fill the name from the signer record if we have it and the
            // user hasn't typed anything yet, so the preview shows immediately.
            if (!this.typedName && this.internalSignerName) {
                this.typedName = this.internalSignerName;
                if (!this.selectedFont) this.selectedFont = this.fontList[0];
            }
            // Always keep initials in sync with the name (unless the signer
            // typed their own). This covers the case where typedName arrived
            // from a saved signature or auto-fill but initials were never
            // derived — without it the Initials box renders empty.
            if (!this._initialsEdited && !this.typedInitials && this.typedName) {
                this.typedInitials = this.deriveInitials(this.typedName);
            }
        }
    }

    handleApplyToAllChange(e) { this.applyToAll = e.target.checked; }

    // "Next field" — scroll the next incomplete field (across pages) into view
    // and open it, so the signer doesn't have to hunt for boxes on every page.
    handleGoNext() {
        const next = this._incompleteFieldsInOrder[0];
        if (!next) return;
        const el = this.template.querySelector('[data-id="' + next.Id + '"]');
        if (el && el.scrollIntoView) {
            el.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
        this.openField(next);
    }

    closeBottomSheet() {
        this.showBottomSheet = false;
        this.activeFieldId = null;
    }

    /* ── Apply field ── */

    applyField() {
        const field = this.activeField;
        if (!field) return;

        let value = '';
        let completed = false;
        // Capture mode so apply-to-all knows what artifact we actually have.
        let sigMode = null; // 'draw' | 'type' | 'upload'

        const isSig = field.Field_Type__c === 'Signature' || field.Field_Type__c === 'Initial';

        if (isSig) {
            if (this.showDraw && this.paths.length > 0) {
                sigMode = 'draw';
                value = JSON.stringify(this.paths); completed = true;
            } else if (this.showType && this.hasTypedName && this.selectedFont) {
                sigMode = 'type';
                // For Initial fields, store the initials; for Signature, the name.
                const text = (field.Field_Type__c === 'Initial')
                    ? (this.typedInitials || this.deriveInitials(this.typedName))
                    : this.typedName;
                value = 'typed:' + text + ':' + this.selectedFont; completed = true;
            } else if (this.showUpload && this.uploadedImage) {
                sigMode = 'upload';
                value = this.uploadedImage; completed = true;
            } else {
                this.showToast('Error', 'Please provide a signature', 'error');
                return;
            }
        } else if (field.Field_Type__c === 'Date Signed') {
            value = this.todayDate; completed = true;
        } else if (field.Field_Type__c === 'Checkbox') {
            value = this.checkboxValue ? 'true' : '';
            completed = this.checkboxValue;
        } else {
            value = this.fieldInputValue;
            completed = value.trim().length > 0;
        }

        // The adopt sheet captures BOTH the full name and initials at once, so in
        // "type" mode a single adopt fills every Signature AND every Initial field
        // (each with the correct text). In draw/upload mode we only have one
        // artifact, so it applies to the active field's own type only.
        const valueFor = (f) => {
            if (sigMode === 'type') {
                const text = (f.Field_Type__c === 'Initial')
                    ? (this.typedInitials || this.deriveInitials(this.typedName))
                    : this.typedName;
                return 'typed:' + text + ':' + this.selectedFont;
            }
            return value;
        };

        // Adopting also settles the signer's own identity fields. The adopt sheet
        // already asked for the full name, and the email is the address this
        // envelope was sent to — there is exactly one right answer for each, so
        // making the signer retype them is pointless friction. Initials have
        // always been filled this way; Full Name and Email were the odd ones out.
        //
        // Deliberately NOT gated on "Apply to all": that switch is about reusing
        // one signature across many boxes, a choice. There is no comparable
        // choice here. Only blank fields are touched, so a signer who edits one
        // by hand keeps their edit.
        const identityValue = (f) => {
            if (f.Field_Type__c === 'Full Name') {
                return (this.typedName || this.internalSignerName || '').trim();
            }
            if (f.Field_Type__c === 'Email') {
                return (this.internalSignerEmail || this.signerEmail || '').trim();
            }
            return null;
        };

        // Sign-all-at-once: with "Apply to all" on, stamp the adopted value onto
        // every still-incomplete signature/initial box. The active field is always
        // updated; already-completed fields are left as-is (not overwritten).
        const fillAll = isSig && completed && this.applyToAll;
        let filledCount = 0;
        let identityFilled = 0;
        this.signerFields = this.signerFields.map(f => {
            const isActive = f.Id === field.Id;
            const fIsSig = f.Field_Type__c === 'Signature' || f.Field_Type__c === 'Initial';

            // Identity autofill, only when this adopt actually produced a signature
            // and only into a box the signer has not filled themselves.
            if (!isActive && isSig && completed && !f.Is_Completed__c) {
                const auto = identityValue(f);
                if (auto) {
                    // Counted separately: filledCount drives a "Signed N signature
                    // fields" toast, and a name or email box is not one of those.
                    identityFilled++;
                    return {
                        ...f,
                        Field_Value__c: auto,
                        Is_Completed__c: true,
                        displayLabel: f.Field_Label__c,
                        fieldClass: 'field-box-completed'
                    };
                }
            }

            // type mode → both signature & initial fields; draw/upload → same type only
            const inApplyGroup = (sigMode === 'type')
                ? fIsSig
                : (f.Field_Type__c === field.Field_Type__c);
            const sameTypeTodo = fillAll && inApplyGroup && !f.Is_Completed__c;
            if (isActive || sameTypeTodo) {
                filledCount++;
                return {
                    ...f,
                    Field_Value__c: isActive ? value : valueFor(f),
                    Is_Completed__c: completed,
                    displayLabel: f.Field_Label__c,
                    fieldClass: completed ? 'field-box-completed' : 'field-box'
                };
            }
            return f;
        });

        this.updateFieldPositions();
        this.closeBottomSheet();
        if (completed) {
            const typeWord = (sigMode === 'type') ? '' : (field.Field_Type__c.toLowerCase() + ' ');
            let msg = (fillAll && filledCount > 1)
                ? ('Signed ' + filledCount + ' ' + typeWord + 'fields')
                : (field.Field_Label__c + ' completed!');
            // Say so when name/email boxes were filled too, otherwise they change
            // on screen with nothing accounting for it.
            if (identityFilled > 0) {
                msg += identityFilled === 1
                    ? ' Your details filled 1 more field.'
                    : (' Your details filled ' + identityFilled + ' more fields.');
            }
            this.showToast('Success', msg, 'success');
        }
    }

    /* ── Drawing ── */

    getCoords(e) {
        const el = e.currentTarget;
        const rect = el.getBoundingClientRect();
        return {
            x: Math.round((e.clientX - rect.left) * (600 / rect.width)),
            y: Math.round((e.clientY - rect.top) * (150 / rect.height))
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
        e.currentTarget.setPointerCapture(e.pointerId);
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
    clearDraw() { this.paths = []; this.currentPath = ''; this.showDrawPlaceholder = true; }

    selectDraw() { this.showDraw = true; this.showType = false; this.showUpload = false; }
    selectType() { this.showDraw = false; this.showType = true; this.showUpload = false; }
    selectUpload() { this.showDraw = false; this.showType = false; this.showUpload = true; }

    // Ordered list of signature fonts available in the style dropdown.
    get fontList() {
        return SIGNATURE_FONTS;
    }

    // Options for the <select> dropdown, with the current one marked selected.
    get fontOptions() {
        const current = this.selectedFont || this.fontList[0];
        return this.fontList.map(f => ({
            value: f,
            label: f,
            selected: f === current
        }));
    }

    handleTypedName(e) {
        this.typedName = String(e.target.value || '').replace(/[<>&`]/g, '');
        // Auto-derive initials from the name (first letter of each word),
        // but only if the user hasn't manually typed their own initials yet.
        if (!this._initialsEdited) {
            this.typedInitials = this.deriveInitials(this.typedName);
        }
        // Default to the first style so the preview is never blank.
        if (!this.selectedFont) {
            this.selectedFont = this.fontList[0];
        }
    }

    handleTypedInitials(e) {
        this.typedInitials = e.target.value;
        this._initialsEdited = true; // stop auto-deriving once user edits
        if (!this.selectedFont) {
            this.selectedFont = this.fontList[0];
        }
    }

    // First letter of up to two words, uppercased. "Nihar Sharma" -> "NS".
    deriveInitials(name) {
        if (!name) return '';
        const words = name.trim().split(/\s+/).filter(Boolean);
        if (words.length === 0) return '';
        if (words.length === 1) return words[0].substring(0, 2).toUpperCase();
        return (words[0][0] + words[words.length - 1][0]).toUpperCase();
    }

    // Dropdown selection — set the chosen font directly.
    handleStyleChange(e) {
        this.selectedFont = e.target.value;
    }

    triggerUpload() {
        const input = this.template.querySelector('input[type="file"]');
        if (!input) return;
        // BUG-026 FIX: reset the value first so re-selecting the SAME file still
        // fires `change`. Without this, after removing an image a second upload
        // was blocked (the input still held the previous file → no change event).
        input.value = '';
        input.click();
    }
    handleFileUpload(e) {
        const input = e.target;
        const file = input.files && input.files[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onload = (evt) => { this.uploadedImage = evt.target.result; };
        reader.onerror = () => { /* ignore - user can retry */ };
        reader.readAsDataURL(file);
        // Clear so the same file can be chosen again next time.
        input.value = '';
    }
    clearUpload() {
        this.uploadedImage = null;
        const input = this.template.querySelector('input[type="file"]');
        if (input) input.value = '';
    }
    handleTextInput(e) { this.fieldInputValue = e.target.value; }
    handleCheckboxInput(e) { this.checkboxValue = e.target.checked; }

    /* ── Complete signing ── */

    async handleComplete() {
        if (this.isSubmitting) return;
        this.isSubmitting = true;
        try {
            // 1. Save field values — preserve full signature data
            const fieldValues = this.signerFields.map(f => {
                let val = f.Field_Value__c || '';
                // Only truncate if absolutely needed for Long Text Area limit
                // (Salesforce LTA max = 131,072 chars). Keep signature data
                // intact otherwise so Lambda can render properly.
                if (val.length > 130000) {
                    console.warn('Field value exceeds storage limit:', f.Id, val.length);
                    val = '';
                }
                return { id: f.Id, value: val };
            });
            await saveFieldValues({
                token: this.token,
                fieldValuesJson: JSON.stringify(fieldValues)
            });

            // 2. Save signature (token-scoped to signer's email)
            // BUG FIX: Previously this read the LIVE tab state (this.showDraw /
            // this.showType). That broke when the signing modal had been closed
            // or the tab had changed after Apply — e.g. a user draws a signature,
            // clicks Apply, then the tab defaults back to "Select Style", and on
            // Complete the code wrongly saved a TYPED signature instead of the
            // drawn one.
            //
            // Correct approach: derive the signature from the actual SAVED value
            // on the completed Signature field. The value format encodes its own
            // type, so we don't need to know which tab was last open:
            //   - Drawn   → JSON array string, e.g. '[{"id":1,"d":"M 10 20..."}]'
            //   - Typed   → 'typed:<name>:<font>'
            //   - Uploaded→ 'data:image/...;base64,...'
            let sigData = '', sigType = 'Draw', fontFamily = '';

            const sigField = this.signerFields.find(f =>
                f && f.Is_Completed__c &&
                (f.Field_Type__c === 'Signature' || f.Field_Type__c === 'Initial') &&
                f.Field_Value__c
            );
            const savedVal = sigField ? sigField.Field_Value__c : '';

            if (savedVal) {
                if (savedVal.startsWith('typed:')) {
                    sigType = 'Type';
                    sigData = savedVal;
                    const parts = savedVal.split(':');
                    fontFamily = parts[2] || '';
                } else if (savedVal.startsWith('data:image')) {
                    sigType = 'Upload';
                    sigData = savedVal;
                } else {
                    // JSON path array → drawn signature
                    sigType = 'Draw';
                    sigData = savedVal;
                }
            } else {
                // Fallback to live state only if no field was saved (edge case)
                if (this.showDraw && this.paths.length > 0) {
                    sigType = 'Draw';
                    sigData = JSON.stringify(this.paths);
                } else if (this.showType && this.typedName) {
                    sigType = 'Type';
                    sigData = 'typed:' + this.typedName + ':' + this.selectedFont;
                    fontFamily = this.selectedFont;
                } else if (this.showUpload && this.uploadedImage) {
                    sigType = 'Upload';
                    sigData = this.uploadedImage;
                }
            }
            if (sigData) {
                try {
                    await saveSignature({
                        token: this.token,
                        sessionToken: this.sessionToken,
                        signatureData: sigData,
                        signatureType: sigType,
                        fontFamily
                    });
                } catch (e) { /* best-effort */ }
            }

            // 3. Capture BOTH public IPs (Salesforce can't expose a guest's IP
            //    server-side, so this is browser-side via trusted IP services):
            //      - IPv6 → Signer Events "Using IP Address" (signer record)
            //      - IPv4 → Audit Trail "Document Signed" event
            //    Each host must be in Setup > Trusted URLs with connect-src.
            const fetchIp = async (url) => {
                const ctrl = new AbortController();
                const tk = setTimeout(() => ctrl.abort(), 4000);
                try {
                    const resp = await fetch(url, { signal: ctrl.signal });
                    const d = await resp.json();
                    return (d && d.ip) ? d.ip : '';
                } catch (e) {
                    console.warn('SVLOG: IP lookup failed for', url, '-', e && (e.message || e));
                    return '';
                } finally {
                    clearTimeout(tk);
                }
            };
            // IPv6 (api6 forces IPv6; api64 is IPv6-preferred fallback)
            let ipV6 = await fetchIp('https://api6.ipify.org?format=json');
            if (!ipV6) ipV6 = await fetchIp('https://api64.ipify.org?format=json');
            // IPv4 (api.ipify.org only resolves A records → always IPv4)
            let ipV4 = await fetchIp('https://api.ipify.org?format=json');
            // Cross-fallback so neither value ends up blank
            if (!ipV6) ipV6 = ipV4;
            if (!ipV4) ipV4 = ipV6;
            console.log('SVLOG: ipV6=', ipV6 || '(none)', 'ipV4=', ipV4 || '(none)');

            // 4. Bundled server flow: mark-signed + stamp + cert + email
            this.loadingMessage = 'Finalizing your signature...';
            this.isLoading = true;

            const result = await completeSigning({
                token: this.token,
                sessionToken: this.sessionToken,
                ipAddress: ipV6,        // Signer "Using IP Address" (IPv6)
                ipAddressV4: ipV4,      // Audit Trail "Document Signed" (IPv4)
                userAgent: navigator.userAgent
            });

            this.signedTimestamp = new Date().toLocaleString();
            this.signerIpAddress = ipV6;
            // certificateId comes back across the Apex boundary, and the scanner
            // traces the navigator.userAgent we sent up into it. It is in fact a
            // server-generated UUID - hex and dashes only - so filtering to that
            // alphabet cannot alter a real value, and nothing else can reach the
            // signing receipt. Same treatment the picked Drive id already gets.
            this.signedCertificateId = String(result.certificateId || '').replace(/[^-A-Za-z0-9]/g, '');
            // Apex already tells us whether THIS signature completed the envelope.
            // The copy only goes out once everyone has signed, so the confirmation
            // has to say different things to the last signer and to a middle one —
            // promising a signed copy "is being emailed" to someone who still has
            // three signers ahead of them is simply untrue, and they wait for a
            // mail that is not coming yet.
            this.agreementFullySigned = result.isCompleted === true;

            this.isLoading = false;
            this.isSigned = true;

            // Certificate render moved out of completeSigning (there it risked an
            // uncatchable governor breach → a 500 that rolled back the signature).
            // Fire it here in its OWN transaction, only for the LAST signer (the
            // one whose completion email carries the documents): fresh limits +
            // live guest session → the certificate renders WITH content, and a
            // failure cannot undo the signature that already succeeded. The async
            // CompletionEmailQueueable remains the fallback.
            if (result.isCompleted === true) {
                generateCertificate({ token: this.token, sessionToken: this.sessionToken })
                    .then((r) => console.log('SVLOG: certificate render →', r && r.success))
                    .catch((e) => console.warn('SVLOG: certificate render call failed (async fallback covers it):', e && (e.body ? e.body.message : e.message)));
            }

            // In-person: hand control back to the record page that opened this
            // tab — tell it to refresh, give the signer a moment to read the
            // confirmation, then close. window.close() only works because the
            // opener created this tab via window.open.
            if (this._inPerson) {
                try {
                    if (window.opener) {
                        window.opener.postMessage({ type: 'signforce_inperson_done' }, '*');
                    }
                } catch (e) { /* cross-window messaging blocked — focus fallback covers it */ }
                setTimeout(() => {
                    try { window.close(); } catch (e) { /* ignore */ }
                }, 3000);
            }
        } catch (e) {
            console.error(e);
            this.showToast('Error', 'Error completing signature. Please try again.', 'error');
            this.isSubmitting = false;
            this.isLoading = false;
        }
    }

    // ── Email verification (OTP) gate ──

    get otpDisplayEmail() {
        if (this.otpMaskedEmail) return this.otpMaskedEmail;
        // Client-side fallback in the server's shape ('va***@domain') so the
        // card never shows a blank address while the first send is in flight.
        const email = this.internalSignerEmail || '';
        const at = email.indexOf('@');
        if (at <= 0) return email;
        return email.substring(0, Math.min(2, at)) + '***' + email.substring(at);
    }

    get otpErrorDisplay() {
        if (!this.otpError) return '';
        // Append the remaining attempts unless the server message already
        // covers them (or the code is locked, where attempts are moot).
        if (!this.otpLocked && this.attemptsLeft != null && this.attemptsLeft > 0
            && this.otpError.toLowerCase().indexOf('attempt') === -1) {
            return this.otpError + ' ' + this.attemptsLeft
                + (this.attemptsLeft === 1 ? ' attempt left.' : ' attempts left.');
        }
        return this.otpError;
    }

    get otpInputDisabled() { return this.otpLocked; }
    get otpVerifyDisabled() {
        return this.otpVerifying || this.otpLocked || (this.otpCode || '').length !== 6;
    }
    get otpVerifyLabel() { return this.otpVerifying ? 'Verifying...' : 'Verify'; }
    get otpResendDisabled() {
        return this.resendCooldown > 0 || this.otpSending || this.otpVerifying;
    }
    get otpResendLabel() {
        if (this.otpSending) return 'Sending...';
        return this.resendCooldown > 0
            ? ('Resend code in ' + this.resendCooldown + 's')
            : 'Resend code';
    }

    async sendOtp(isAuto) {
        if (this.otpSending || this.resendCooldown > 0) return;
        this.otpSending = true;
        try {
            const res = await sendSigningOtp({ token: this.token });
            if (res && res.maskedEmail) this.otpMaskedEmail = String(res.maskedEmail).replace(/[<>&"'`]/g, '');
            const cd = Number(res && res.cooldownSeconds) || 0;
            if (res && res.success) {
                // Fresh code out: the attempt counter restarted server-side,
                // so a lock from the previous code no longer applies.
                this.otpLocked = false;
                this.attemptsLeft = null;
                this.otpError = '';
                this._clearOtpInput();
                this._startCooldown(cd > 0 ? cd : 60);
            } else if (cd > 0) {
                // Refused because one went out moments ago (refresh spam). That
                // emailed code is still valid — no error, just the countdown.
                this._startCooldown(cd);
            } else if (!isAuto) {
                this.otpError = (res && res.message) || 'Could not send the code. Please try again.';
            } else {
                this.otpError = 'We could not send your code. Use Resend to try again.';
            }
        } catch (e) {
            console.error('SVLOG: sendSigningOtp failed:', e && (e.body ? e.body.message : e.message));
            this.otpError = isAuto
                ? 'We could not send your code. Use Resend to try again.'
                : 'Could not send the code. Please try again.';
        } finally {
            this.otpSending = false;
        }
    }

    handleOtpResend() {
        if (this.otpResendDisabled) return;
        this.sendOtp(false);
    }

    handleOtpInput(e) {
        const digits = (e.target.value || '').replace(/\D/g, '').slice(0, 6);
        // Write the sanitized value back to the DOM: with a plain input, the
        // tracked property alone won't correct the field when it didn't change.
        if (e.target.value !== digits) e.target.value = digits;
        this.otpCode = digits;
        this.otpError = '';
        if (digits.length === 6 && !this.otpVerifying && !this.otpLocked) {
            this.handleOtpVerify();
        }
    }

    // maxlength="6" would clip a pasted "123 456" to "123 45", so paste is
    // intercepted and the digits extracted from the raw clipboard text.
    handleOtpPaste(e) {
        e.preventDefault();
        const text = (e.clipboardData && e.clipboardData.getData('text')) || '';
        const digits = text.replace(/\D/g, '').slice(0, 6);
        if (!digits) return;
        e.target.value = digits;
        this.otpCode = digits;
        this.otpError = '';
        if (digits.length === 6 && !this.otpVerifying && !this.otpLocked) {
            this.handleOtpVerify();
        }
    }

    handleOtpKeydown(e) {
        if (e.key === 'Enter' && !this.otpVerifyDisabled) this.handleOtpVerify();
    }

    async handleOtpVerify() {
        if (this.otpVerifying || this.otpLocked) return;
        const code = (this.otpCode || '').trim();
        if (code.length !== 6) { this.otpError = 'Enter the 6-digit code from your email.'; return; }
        this.otpVerifying = true;
        this.otpError = '';
        try {
            const res = await verifySigningOtp({ token: this.token, code });
            if (res && res.verified) {
                await this._openAfterOtp();
            } else {
                this.otpLocked = !!(res && res.locked);
                this.attemptsLeft = (res && res.attemptsLeft != null) ? Number(res.attemptsLeft) : null;
                this.otpError = (res && res.message)
                    || (this.otpLocked
                        ? 'Too many incorrect attempts. Request a new code to continue.'
                        : 'That code is not correct.');
                this._clearOtpInput();
            }
        } catch (e) {
            console.error('SVLOG: verifySigningOtp failed:', e && (e.body ? e.body.message : e.message));
            this.otpError = 'Could not verify the code. Please try again.';
        } finally {
            this.otpVerifying = false;
        }
    }

    // Per-tab OTP proof. sessionStorage is scoped to a single tab and survives a
    // refresh of that tab, but a new tab or window starts empty — exactly the
    // boundary we want the verification code to re-guard.
    _tabOtpKey(tok) { return 'sf_otp_' + tok; }

    _tabHasOtp(tok) {
        try { return window.sessionStorage.getItem(this._tabOtpKey(tok)) === '1'; }
        catch (e) { return false; }   // storage blocked → re-gate, the safe default
    }

    _markTabOtp(tok) {
        try { window.sessionStorage.setItem(this._tabOtpKey(tok), '1'); }
        catch (e) { /* storage blocked — gate will simply show again next load */ }
    }

    /** Verified: drop the gate and let the normal render path take over. */
    async _openAfterOtp() {
        clearInterval(this._otpCooldownTimer);
        this._otpCooldownTimer = null;
        this.otpVerified = true;
        this._markTabOtp(this.token);
        this.showOtpGate = false;
        // A held session skipped its payload load while the gate was up.
        if (this._otpPayloadDeferred) {
            this._otpPayloadDeferred = false;
            this.isLoading = true;
            await this.loadSigningPayload();
            this.isLoading = false;
        }
    }

    _clearOtpInput() {
        this.otpCode = '';
        const inp = this.template.querySelector('.otp-input');
        if (inp) inp.value = '';
    }

    _startCooldown(seconds) {
        clearInterval(this._otpCooldownTimer);
        this.resendCooldown = Math.max(0, Math.floor(Number(seconds) || 0));
        if (this.resendCooldown === 0) return;
        this._otpCooldownTimer = setInterval(() => {
            if (this.resendCooldown <= 1) {
                this.resendCooldown = 0;
                clearInterval(this._otpCooldownTimer);
                this._otpCooldownTimer = null;
            } else {
                this.resendCooldown -= 1;
            }
        }, 1000);
    }

    // ── E-sign consent gate ──
    handleConsentToggle(e) {
        this.consentChecked = e.target.checked;
    }

    get consentContinueDisabled() {
        return !this.consentChecked;
    }

    async handleConsentContinue() {
        if (!this.consentChecked || this._consentBusy) return;
        this._consentBusy = true;

        // The link is claimed for this browser HERE, on a real gesture — not on
        // page load. Email security scanners fetch and even render signing links
        // to check them, but they do not tick a consent box and press Continue,
        // so they can no longer swallow the signer's session.
        if (!this.sessionToken) {
            this.isLoading = true;
            const claimed = await this.claimSession(this.token);
            if (!claimed) {
                this.sessionTimedOut = true;
                this.isLoading = false;
                this._consentBusy = false;
                return;
            }
            await this.loadSigningPayload();
        }

        this.isLoading = false;
        this.consentGiven = true;
        this._consentBusy = false;

        // Record the consent acceptance as its own audit-trail row, in the
        // background. Fire-and-forget and fully guarded: an IP lookup or audit
        // failure must never hold up or block the signer.
        this._logConsentAccepted();
    }

    async _logConsentAccepted() {
        try {
            let ip = '';
            try {
                const controller = new AbortController();
                const t = setTimeout(() => controller.abort(), 4000);
                const r = await fetch('https://api.ipify.org?format=json', { signal: controller.signal });
                clearTimeout(t);
                if (r && r.ok) ip = (await r.json()).ip || '';
            } catch (ipErr) { /* IP is best-effort */ }

            await logConsentAccepted({
                token: this.token,
                ipAddress: ip,
                userAgent: navigator.userAgent
            });
        } catch (e) {
            // Swallow — the consent gate has already opened.
            console.warn('SVLOG: consent audit skipped -', e && (e.message || e));
        }
    }

    async handleDecline() {
        const dialog = this.template.querySelector('c-signforce-confirm');
        const reason = await dialog.open({
            title: 'Decline to sign',
            message: 'The sender will be told you declined. Let them know why - this is shared with them.',
            input: true,
            placeholder: 'Reason for declining',
            required: true,
            confirmLabel: 'Decline',
            variant: 'danger'
        });
        if (reason === null) return;   // cancelled

        try {
            await declineAgreement({ token: this.token, sessionToken: this.sessionToken, reason });
            this.errorMessage = 'You have declined to sign this document.';
            this.hasError = true;
        } catch (e) {
            this.showToast('Could not decline', 'Please try again, or contact the sender.', 'error');
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import createAgreement from '@salesforce/apex/AgreementController.createAgreement';
// BUG-037/042/043/063 FIX: persist Step-1 edits made after the record exists.
import updateAgreement from '@salesforce/apex/AgreementController.updateAgreement';
import addSigner from '@salesforce/apex/AgreementController.addSigner';
import updateSigner from '@salesforce/apex/AgreementController.updateSigner';
import deleteSigner from '@salesforce/apex/AgreementController.deleteSigner';
import sendForSignature from '@salesforce/apex/AgreementController.sendForSignature';
import getFieldCount from '@salesforce/apex/DocumentEditorController.getFieldCount';
// Tiered storage imports:
import getStorageTierForUpload from '@salesforce/apex/AgreementController.getStorageTierForUpload';
import uploadTier1Document from '@salesforce/apex/AgreementController.uploadTier1Document';
import createAgreementDocumentS3 from '@salesforce/apex/AgreementController.createAgreementDocumentS3';
import initChunkedUpload from '@salesforce/apex/AgreementController.initChunkedUpload';
// Chunked-to-Salesforce upload (no S3): the browser slices the base64 into
// heap-safe pieces; an async Queueable reassembles the file server-side.
import storeOriginalChunk from '@salesforce/apex/SalesforceChunkUpload.storeOriginalChunk';
import isOriginalReady from '@salesforce/apex/SalesforceChunkUpload.isOriginalReady';
// >4MB path: the document goes to the connected cloud provider (Google Drive /
// OneDrive) instead of Salesforce/S3. prepareCloudUpload ensures the folders
// exist; createAgreementDocumentCloud records the cloud file handle.
import prepareCloudUpload from '@salesforce/apex/AgreementController.prepareCloudUpload';
import createAgreementDocumentCloud from '@salesforce/apex/AgreementController.createAgreementDocumentCloud';
import pushCloudChunk from '@salesforce/apex/AgreementController.pushCloudChunk';

import searchExistingSigners from '@salesforce/apex/AgreementController.searchExistingSigners';
import { stripNs } from 'c/nsUtils';

// Largest file we accept. Every document is stored in Salesforce Files (never
// S3); the chunked upload + async reassembly keeps it under the Apex heap. The
// server-side assembly must hold the whole base64 + decoded blob at once, which
// caps the reliable size at ~4 MB within the 12 MB async heap.
const SALESFORCE_ONLY_MAX_BYTES = 4 * 1024 * 1024; // 4 MB

// Base64 characters per chunk sent to Apex. Kept a multiple of 4 (whole 3-byte
// groups) so concatenating the chunks' base64 reproduces the file exactly, and
// small enough that each synchronous Apex call stays well under the 6 MB heap.
const B64_CHUNK_CHARS = 1000000; // ~0.75 MB decoded per chunk

// How long to wait for the async reassembly before giving up.
const ASSEMBLY_POLL_MS = 1000;
const ASSEMBLY_MAX_TRIES = 40;

export default class CreateAgreement extends NavigationMixin(LightningElement) {
    @track currentStep = 1;
    @track isLoading = false;
    @track signersSaved = false;

    // Step 1
    @track agreementName = '';
    @track agreementType = 'Other';
    @track signingOrder = 'Sequential';
    @track expiryDate = '';
    @track message = '';

    // Step 2
    @track uploadedDoc = null;
    @track uploadProgress = 0;
    @track uploadStatusText = '';
    @track uploadedDocStorageLabel = '';

    // S3 state
    s3DocId = null;
    s3Url = null;
    s3Tier = null;

    // Step 3
    @track signers = [{
        key: '1', name: '', email: '', role: 'Signer', order: 1,
        searchTerm: '', suggestions: [], showSuggestions: false
    }];

    @track fieldsPlaced = false;
    agreementId = null;

    // CMT config
    _config = null;

    typeOptions = [
        { label: 'NDA', value: 'NDA' },
        { label: 'Contract', value: 'Contract' },
        { label: 'Proposal', value: 'Proposal' },
        { label: 'Invoice', value: 'Invoice' },
        { label: 'HR Document', value: 'HR Document' },
        { label: 'Other', value: 'Other' }
    ];
    orderOptions = [
        { label: 'Sequential (one at a time)', value: 'Sequential' },
        { label: 'Parallel (all at once)', value: 'Parallel' }
    ];
    roleOptions = [
        { label: 'Signer', value: 'Signer' },
        { label: 'CC Only', value: 'CC' }
    ];

    /* ── Wired CMT config ── */

    @wire(getStorageTierForUpload)
    wiredConfig({ data, error }) {
        if (data) {
            this._config = data;
            console.log('[SignForce] Storage config:', JSON.stringify(data));
        } else if (error) {
            // If the wire fails (CMT not deployed yet, network error, etc.)
            // we fall back to safe defaults. lambdaEndpoint is intentionally
            // left empty — the upload code below will throw a clear error
            // ("Lambda endpoint not configured") rather than silently POSTing
            // to a stale hardcoded URL.
            console.error('[SignForce] Failed to load storage config, using fallbacks', error);
            this._config = {
                tier: 'Tier1',
                lambdaEndpoint: '',
                tier1MaxBytes: 3145728,
                chunkThresholdBytes: 7340032,
                maxUploadBytes: 20971520,
                orgId: '',
                cloudProvider: null,
                cloudConnected: false
            };
        }
    }

    /**
     * True when a cloud provider is enabled and has a destination folder. Assumed
     * true until the config wire resolves, so the existing dropzone doesn't flash
     * the "using Salesforce storage" warning on every page load. UI hints only —
     * routing must use `useCloudStorage`, which never guesses.
     */
    get cloudConnected() {
        return this._config ? !!this._config.cloudConnected : true;
    }

    /**
     * Routing decision: send this document to the cloud provider?
     *
     * A connected provider takes EVERY document regardless of size — Salesforce
     * Files is only the fallback when nothing is connected. Unlike the hint getter
     * above this must not be optimistic: if the config hasn't resolved we'd hand a
     * file to a provider that isn't there, so an unloaded config means "no cloud".
     */
    get useCloudStorage() {
        return !!(this._config && this._config.cloudConnected);
    }

    /**
     * Upload ceiling for the Salesforce-Files fallback (no cloud connected). This
     * is what the chunked base64 path can carry through the Apex heap; it does not
     * apply once a cloud provider is connected.
     */
    get salesforceStorageLimitBytes() {
        return SALESFORCE_ONLY_MAX_BYTES;
    }

    get salesforceStorageLimitLabel() {
        const mb = this.salesforceStorageLimitBytes / 1048576;
        return `${Number.isInteger(mb) ? mb : mb.toFixed(1)} MB`;
    }

    /* ── Step getters ── */
    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get isStep4() { return this.currentStep === 4; }
    get isStep5() { return this.currentStep === 5; }
    get showBack() { return this.currentStep > 1; }
    get showSaveDraft() { return this.currentStep === 5; }
    get showRemoveSigner() { return this.signers.length > 1; }

    get steps() {
        const labels = ['Details', 'Document', 'Signers', 'Fields', 'Review'];
        return labels.map((label, i) => {
            const stepNum = i + 1;
            const isActive = this.currentStep === stepNum;
            const isComplete = this.currentStep > stepNum;
            let dotClass = 'step-dot';
            if (isActive) dotClass += ' step-dot-active';
            else if (isComplete) dotClass += ' step-dot-complete';
            let labelClass = 'step-label';
            if (isActive) labelClass += ' step-label-active';
            else if (isComplete) labelClass += ' step-label-complete';
            return { id: stepNum, label, isComplete, wrapperClass: 'step-wrapper', dotClass, labelClass };
        });
    }

    get shellClass() { return this.currentStep === 4 ? 'wizard-shell editor-mode' : 'wizard-shell'; }
    get containerClass() { return this.currentStep === 4 ? 'wizard-container editor-active' : 'wizard-container'; }
    get progressFillStyle() { return `width:${((this.currentStep - 1) / 4) * 100}%;`; }

    get uploadedDocIcon() {
        if (!this.uploadedDoc) return 'doctype:unknown';
        return this.uploadedDoc.name.endsWith('.pdf') ? 'doctype:pdf' : 'doctype:word';
    }
    get uploadedDocSize() {
        if (!this.uploadedDoc || !this.uploadedDoc.size) return '';
        const bytes = this.uploadedDoc.size;
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
        return (bytes / (1024 * 1024)).toFixed(2) + ' MB';
    }
    get reviewDocName() {
        return this.uploadedDoc ? this.uploadedDoc.name : 'No document (upload later)';
    }
    // BUG-021 FIX: getter so Step 5 review can conditionally render the
    // "Message to Signers" block — was previously missing from review entirely.
    get hasMessage() {
        return !!(this.message && this.message.trim());
    }
    get tempAgreementId() { return this.agreementId; }
    get isUploading() { return this.uploadProgress > 0 && this.uploadProgress < 100; }
    get uploadProgressStyle() { return `width:${this.uploadProgress}%;height:100%;background:#2563eb;transition:width 200ms;`; }

    /* ── Lifecycle ── */
    _headerHidden = false;
    renderedCallback() {
        if (!this._headerHidden) {
            this._headerHidden = true;
            this.hidePageHeader();
        }
    }
    hidePageHeader() {
        try {
            let el = this.template.host;
            while (el) {
                el = el.parentElement || el.parentNode?.host;
                if (!el) break;
                const header = el.querySelector('.slds-page-header.flexipageHeader');
                if (header) { header.style.display = 'none'; break; }
            }
        } catch (e) { /* swallow */ }
    }

    /* ── Step 1 handlers ── */
    handleNameChange(e) { this.agreementName = e.target.value; }
    handleTypeChange(e) { this.agreementType = e.target.value; }
    handleOrderChange(e) { this.signingOrder = e.target.value; }
    handleExpiryChange(e) {
        // BUG-001 + BUG-053 FIX: reject past dates, and treat "today" with a
        // contextual message instead of the wrong "cannot be in the past".
        // Compare by CALENDAR DATE (date-part strings), not timestamps, so the
        // time-of-day never flags today as past (and it's timezone-safe).
        const v = e.target.value;
        if (v) {
            const pickedDay = String(v).slice(0, 10); // 'YYYY-MM-DD'
            const t = new Date();
            const todayDay = t.getFullYear()
                + '-' + String(t.getMonth() + 1).padStart(2, '0')
                + '-' + String(t.getDate()).padStart(2, '0');
            if (/^\d{4}-\d{2}-\d{2}$/.test(pickedDay)) {
                if (pickedDay < todayDay) {
                    this.showToast('Invalid date', 'Expiry date cannot be in the past.', 'error');
                    this.expiryDate = ''; resetInput(); return;
                }
                if (pickedDay === todayDay) {
                    this.showToast('Invalid date', 'Expiry date cannot be set to today - choose a future date.', 'error');
                    this.expiryDate = ''; resetInput(); return;
                }
            }
        }
        this.expiryDate = v;
    }
    handleMessageChange(e) { this.message = e.target.value; }

    // BUG-049 / BUG-055 FIX: Step 5 review showed the raw ISO datetime
    // (e.g. 2026-07-04T11:30:00.000Z). Format it human-readable.
    get reviewExpiry() {
        if (!this.expiryDate) return '-';
        const d = new Date(this.expiryDate);
        if (isNaN(d.getTime())) return this.expiryDate;
        return d.toLocaleString('en-US', {
            year: 'numeric', month: 'short', day: 'numeric',
            hour: 'numeric', minute: '2-digit', hour12: true
        });
    }

    /* ── Step 2: native input → tier router ── */

    // BUG-003 FIX: track hover state for visual feedback during drag
    @track isDragging = false;
    get dropzoneClass() {
        return this.isDragging ? 'upload-dropzone upload-dropzone-active' : 'upload-dropzone';
    }


    triggerDocUpload() {
        const el = this.template.querySelector('input[type="file"]');
        if (el) el.click();
    }

    // BUG-003 FIX: drag-and-drop handlers. All four events must call
    // preventDefault to override browser's default "open file" behavior.
    handleDragEnter(e) {
        e.preventDefault();
        e.stopPropagation();
        this.isDragging = true;
    }
    handleDragOver(e) {
        // Must preventDefault here too or `drop` never fires.
        e.preventDefault();
        e.stopPropagation();
        if (e.dataTransfer) { e.dataTransfer.dropEffect = 'copy'; }
        this.isDragging = true;
    }
    handleDragLeave(e) {
        e.preventDefault();
        e.stopPropagation();
        this.isDragging = false;
    }
    handleDrop(e) {
        e.preventDefault();
        e.stopPropagation();
        this.isDragging = false;
        const files = e.dataTransfer && e.dataTransfer.files;
        if (!files || files.length === 0) return;
        // Route through the same handler the file input uses. We synthesize a
        // minimal event shape so handleDocUpload doesn't need to change.
        this.handleDocUpload({
            target: {
                files: [files[0]],
                value: ''  // make `e.target.value = ''` safe at the end
            }
        });
    }

    // async handleDocUpload(e) {
    //     const file = e.target.files[0];
    //     if (!file) return;

    //     if (!this._config) {
    //         this.showToast('Error', 'Storage config still loading — try again in a moment.', 'error');
    //         resetInput();
    //         return;
    //     }
    //     if (file.size > this._config.maxUploadBytes) {
    //         const cap = (this._config.maxUploadBytes / (1024 * 1024)).toFixed(0);
    //         this.showToast('Error', `File exceeds ${cap}MB cap.`, 'error');
    //         resetInput();
    //         return;
    //     }
    //     if (!this.agreementId) {
    //         this.showToast('Error', 'Agreement not yet created — go back to Step 1.', 'error');
    //         resetInput();
    //         return;
    //     }

    //     // Resolve effective tier based on org config + file size.
    //     let tier = this._config.tier;
    //     if (tier !== 'Tier1' && file.size <= this._config.tier1MaxBytes) tier = 'Tier1';
    //     if (file.size > this._config.chunkThresholdBytes) tier = 'Tier3';

    //     console.log(`[SignForce] Routing file (${(file.size / 1048576).toFixed(2)}MB) → ${tier}`);

    //     this.uploadedDoc = file;
    //     this.uploadProgress = 1;
    //     this.uploadStatusText = 'Preparing upload…';

    //     try {
    //         if (tier === 'Tier1') {
    //             await this.uploadTier1(file);
    //         } else if (tier === 'Tier2') {
    //             await this.uploadTier2Direct(file);
    //         } else {
    //             await this.uploadTier3Chunked(file);
    //         }
    //     } catch (err) {
    //         // Surface the actual error — Apex AuraHandledException messages live in
    //         // err.body.message; fetch errors live in err.message; everything else
    //         // gets a JSON dump so we never see "Upload failed" with no detail.
    //         const apexMsg = err && err.body && (err.body.message || err.body.pageErrors?.[0]?.message);
    //         const message = apexMsg || (err && err.message) || JSON.stringify(err);
    //         console.error('[SignForce] Upload failed:', message, err);
    //         this.showToast('Error', 'Upload failed: ' + message, 'error', 'sticky');
    //         this.uploadProgress = 0;
    //         this.uploadedDoc = null;
    //     } finally {
    //         resetInput();
    //     }
    // }

    async handleDocUpload(e) {
        // Capture the input element up front. Under Lightning Web Security (and
        // on mobile), the event's `target` can become undefined after an `await`,
        // so a later `e.target.value = ''` threw "Cannot set properties of
        // undefined (setting 'value')" — crashing the whole component AFTER the
        // upload. Hold a direct reference and reset through it instead.
        const inputEl = e && e.target;
        const resetInput = () => { try { if (inputEl) inputEl.value = ''; } catch (ignore) { /* not resettable */ } };
        const file = (inputEl && inputEl.files) ? inputEl.files[0] : null;
        if (!file) return;

        if (!this._config) {
            this.showToast('Error', 'Storage config still loading - try again in a moment.', 'error');
            resetInput();
            return;
        }
        if (file.size > this._config.maxUploadBytes) {
            const cap = (this._config.maxUploadBytes / (1024 * 1024)).toFixed(0);
            this.showToast('Error', `File exceeds ${cap}MB cap.`, 'error');
            resetInput();
            return;
        }
        if (!this.agreementId) {
            this.showToast('Error', 'Agreement not yet created - go back to Step 1.', 'error');
            resetInput();
            return;
        }

        // ── File type detection ──
        // Detect by CONTENT (magic bytes), NOT just the file name. A Word file
        // renamed/saved as .pdf is really a ZIP ("PK\x03\x04"); a real PDF starts
        // with "%PDF". Routing a Word file down the PDF path stores raw ZIP bytes
        // that pdf.js cannot render later — the "Invalid PDF structure" error.
        const lowerName = (file.name || '').toLowerCase();
        const isPdfExt  = lowerName.endsWith('.pdf');
        const isDocExt  = lowerName.endsWith('.doc');
        const isDocxExt = lowerName.endsWith('.docx');
        if (!isPdfExt && !isDocExt && !isDocxExt) {
            this.showToast('Unsupported file type', 'Only PDF, DOC, and DOCX are supported.', 'error');
            resetInput();
            return;
        }

        // Content is authoritative when recognised; extension is the fallback.
        const sniff = await this.sniffMagic(file);   // 'pdf' | 'zip' | 'unknown'
        let treatAsWord;
        let treatAsPdf;
        if (sniff === 'pdf')      { treatAsPdf = true;  treatAsWord = false; }
        else if (sniff === 'zip') { treatAsWord = true; treatAsPdf = false; } // ZIP = DOC/DOCX even if named .pdf
        else                      { treatAsWord = isDocExt || isDocxExt; treatAsPdf = isPdfExt; }

        if (!treatAsWord && !treatAsPdf) {
            this.showToast('Unsupported file', 'This file is not a readable PDF or Word document.', 'error');
            resetInput();
            return;
        }

        // Routing: a connected cloud provider takes EVERY document, whatever its
        // size — Google Drive / OneDrive is the store, and Salesforce Files is only
        // the fallback for orgs with nothing connected. The size ceiling therefore
        // only applies to that fallback (it's an Apex-heap limit, not a cloud one).
        // S3 is never used.
        const useCloud = this.useCloudStorage;
        const overLimit = file.size > this.salesforceStorageLimitBytes;

        if (!useCloud && overLimit) {
            this.showToast(
                'File too large',
                `Files over ${this.salesforceStorageLimitLabel} need a connected cloud provider (Google Drive). ` +
                    `Connect one in eSignforce Admin Config, or upload a file ${this.salesforceStorageLimitLabel} or smaller. ` +
                    `This file is ${(file.size / 1048576).toFixed(1)} MB.`,
                'error',
                'sticky'
            );
            resetInput();
            return;
        }

        this.uploadedDoc = file;
        this.uploadProgress = 1;
        this.uploadStatusText = 'Preparing upload…';

        try {
            if (useCloud) {
                // Cloud connected -> everything goes there, any size.
                if (treatAsWord) await this.uploadWordToCloud(file);
                else await this.uploadPdfToCloud(file);
            } else if (treatAsWord) {
                // DOC/DOCX: Lambda converts to PDF, then the PDF is stored in Salesforce.
                await this.uploadWordViaLambda(file);
            } else {
                // PDF: chunk straight into Salesforce Files.
                await this.uploadPdfToSalesforce(file);
            }
        } catch (err) {
            const apexMsg = err && err.body && (err.body.message || err.body.pageErrors?.[0]?.message);
            const message = apexMsg || (err && err.message) || JSON.stringify(err);
            console.error('[SignForce] Upload failed:', message, err);
            this.showToast('Error', 'Upload failed: ' + message, 'error', 'sticky');
            this.uploadProgress = 0;
            this.uploadedDoc = null;
        } finally {
            resetInput();
        }
    }

    /* ── DOC/DOCX path: Lambda converts to PDF + stores in S3 (uses Tier2 flow) ── */
    async uploadWordViaLambda(file) {
        this.uploadStatusText = 'Reading document…';
        const base64 = await this.fileToBase64(file);
        this.uploadProgress = 20;

        if (!this._config.lambdaEndpoint) {
            throw new Error(
                'Lambda endpoint is not configured. Ask your admin to set ' +
                'Lambda_Endpoint__c on the SignForce_Config__mdt "Default" record.'
            );
        }

        this.uploadStatusText = 'Converting to PDF…';
        const docId = `${this.agreementId}_${Date.now()}`;
        // The Lambda is a conversion service only: returnBase64 hands the PDF
        // back so we store it in Salesforce Files ourselves (never S3).
        const res = await fetch(this._config.lambdaEndpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                action: 'convertToPdf',
                orgId: this._config.orgId,
                docId: docId,
                base64: base64,
                filename: file.name,
                returnBase64: true
            })
        });
        if (!res.ok) {
            const txt = await res.text();
            throw new Error('Conversion failed: HTTP ' + res.status + ' ' + txt.slice(0, 200));
        }
        const json = await res.json();
        if (!json.success || !json.pdfBase64) {
            throw new Error(
                'Conversion did not return the PDF. Deploy the current eSignforce Lambda, ' +
                    'which supports returnBase64.'
            );
        }

        const pdfFileName = file.name.replace(/\.(doc|docx)$/i, '.pdf');
        this.uploadProgress = 40;
        await this.uploadToSalesforceChunked(json.pdfBase64, pdfFileName);
        this.uploadedDocStorageLabel = 'Salesforce';
        this.showToast('Success', 'Document converted and saved.', 'success');
    }

    /* ── PDF path: chunk the file straight into Salesforce Files (no S3) ── */
    async uploadPdfToSalesforce(file) {
        this.uploadStatusText = 'Reading document…';
        const base64 = await this.fileToBase64(file);
        this.uploadProgress = 20;
        await this.uploadToSalesforceChunked(base64, file.name);
        this.uploadedDocStorageLabel = 'Salesforce';
        this.showToast('Success', 'Document saved.', 'success');
    }

    /**
     * Send a base64 document to Salesforce in heap-safe chunks, then wait for the
     * server-side reassembly to finish. The base64 is split on 4-char (whole
     * 3-byte) boundaries so the chunks concatenate back to the exact file.
     */
    async uploadToSalesforceChunked(base64, fileName) {
        const sessionKey = `${this.agreementId}_${Date.now()}`;
        const total = Math.ceil(base64.length / B64_CHUNK_CHARS);

        for (let i = 0; i < total; i++) {
            const slice = base64.substring(i * B64_CHUNK_CHARS, (i + 1) * B64_CHUNK_CHARS);
            // eslint-disable-next-line no-await-in-loop
            await storeOriginalChunk({
                agreementId: this.agreementId,
                sessionKey,
                chunkIndex: i,
                totalChunks: total,
                base64: slice,
                fileName
            });
            this.uploadProgress = 40 + Math.round(((i + 1) / total) * 45); // 40 → 85%
            this.uploadStatusText = `Uploading… ${i + 1}/${total}`;
        }

        // The last chunk enqueued the async reassembly; wait for the Original doc.
        this.uploadStatusText = 'Finalizing…';
        this.uploadProgress = 90;
        await this.waitForOriginalReady();
        this.uploadProgress = 100;
        this.uploadStatusText = 'Saved to Salesforce.';
    }

    async waitForOriginalReady() {
        for (let tries = 0; tries < ASSEMBLY_MAX_TRIES; tries++) {
            // eslint-disable-next-line no-await-in-loop
            const ready = await isOriginalReady({ agreementId: this.agreementId });
            if (ready) return;
            // eslint-disable-next-line no-await-in-loop
            await new Promise((r) => setTimeout(r, ASSEMBLY_POLL_MS));
        }
        throw new Error('The document is taking too long to finalize. Please try again.');
    }

    /* ── >4MB PDF: upload straight to the connected cloud provider (no S3) ── */
    async uploadPdfToCloud(file) {
        this.uploadStatusText = 'Preparing cloud folder…';
        const prep = await prepareCloudUpload({ agreementId: this.agreementId });
        this.uploadProgress = 20;
        this.uploadStatusText = 'Reading document…';
        const base64 = await this.fileToBase64(file);
        await this.pushBase64ToCloud(base64, file.name, file.size, prep);
    }

    /* ── >4MB Word: convert to PDF via Lambda, then upload the PDF to the cloud ── */
    async uploadWordToCloud(file) {
        this.uploadStatusText = 'Preparing cloud folder…';
        const prep = await prepareCloudUpload({ agreementId: this.agreementId });
        this.uploadProgress = 15;
        if (!this._config.lambdaEndpoint) throw new Error('Lambda endpoint is not configured.');
        this.uploadStatusText = 'Reading document…';
        const wordBase64 = await this.fileToBase64(file);
        this.uploadStatusText = 'Converting to PDF…';
        const res = await fetch(this._config.lambdaEndpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                action: 'convertToPdf',
                orgId: this._config.orgId,
                docId: `${this.agreementId}_${Date.now()}`,
                base64: wordBase64,
                filename: file.name,
                returnBase64: true
            })
        });
        if (!res.ok) {
            const t = await res.text();
            throw new Error('Conversion failed: HTTP ' + res.status + ' ' + t.slice(0, 200));
        }
        const json = await res.json();
        if (!json.success || !json.pdfBase64) throw new Error('Conversion did not return the PDF.');
        const pdfName = file.name.replace(/\.(doc|docx)$/i, '.pdf');
        await this.pushBase64ToCloud(json.pdfBase64, pdfName, json.size || file.size, prep);
    }

    /* ── Push a PDF (base64) to the cloud provider in chunks, then record it ── */
    async pushBase64ToCloud(base64, fileName, fileSize, prep) {
        this.uploadStatusText = 'Uploading to cloud…';
        if (!this._config.lambdaEndpoint) throw new Error('Lambda endpoint is not configured.');
        // A >4MB file's base64 exceeds Lambda's 6MB payload, so send it in pieces
        // (each POST ~3MB). The last chunk assembles + uploads and returns the id.
        // Route each chunk through Apex (browser -> Apex -> Lambda) so there is no
        // direct browser->Lambda call and CORS never applies. Chunks kept small to
        // stay under the Apex heap.
        const CHARS = 2000000;
        const sessionId = `${this.agreementId}_${Date.now()}`;
        const total = Math.ceil(base64.length / CHARS);
        let externalId = null;
        for (let i = 0; i < total; i++) {
            // eslint-disable-next-line no-await-in-loop
            const id = await pushCloudChunk({
                sessionId,
                chunkIndex: i,
                totalChunks: total,
                chunkBase64: base64.substring(i * CHARS, (i + 1) * CHARS),
                provider: prep.provider,
                folderId: prep.originalFolderId,
                fileName
            });
            if (i === total - 1) externalId = id;
            this.uploadProgress = 40 + Math.round(((i + 1) / total) * 45);
            this.uploadStatusText = `Uploading… ${i + 1}/${total}`;
        }
        if (!externalId) throw new Error('Cloud did not return a file id.');
        this.uploadProgress = 90;
        this.uploadStatusText = 'Recording…';
        await createAgreementDocumentCloud({
            agreementId: this.agreementId,
            cloudFileId: externalId,
            provider: prep.provider,
            folderId: prep.originalFolderId,
            fileName,
            fileSize
        });
        this.uploadProgress = 100;
        this.uploadStatusText = 'Saved to cloud.';
        this.uploadedDocStorageLabel = prep.provider === 'OneDrive' ? 'OneDrive' : 'Google Drive';
        this.showToast('Success', 'Document uploaded to cloud.', 'success');
    }

    removeDoc() {
        this.uploadedDoc = null;
        this.uploadedDocStorageLabel = '';
        this.uploadProgress = 0;
        this.uploadStatusText = '';
    }

    /* ── Step 3 handlers ── */
    handleSignerChange(e) {
        const idx = parseInt(e.target.dataset.index, 10);
        const field = e.target.dataset.field;
        const signers = JSON.parse(JSON.stringify(this.signers));
        signers[idx][field] = e.target.value;
        this.signers = signers;
    }

    addSigner() {
        this.signers = [...this.signers, {
            key: Date.now().toString(),
            name: '', email: '', role: 'Signer',
            order: this.signers.length + 1,
            searchTerm: '', suggestions: [], showSuggestions: false
        }];
    }

    removeSigner(e) {
        const idx = parseInt(e.currentTarget.dataset.index, 10);
        // BUG-013 FIX: after removing, re-sequence signing orders 1..N so the
        // numbering stays contiguous (was leaving gaps like 1, 2, 4).
        const remaining = this.signers.filter((_, i) => i !== idx);
        remaining.forEach((s, i) => { s.order = i + 1; });
        this.signers = remaining;
    }

    /* ── Existing-signer search (autofill) ── */

    handleSignerSearch(e) {
        const idx = parseInt(e.currentTarget.dataset.index, 10);
        const term = (e.target.value || '').trim();

        const signers = JSON.parse(JSON.stringify(this.signers));
        // Update the search term for this row
        signers[idx].searchTerm = term;

        // BUG-005 FIX: when user clears the search field after auto-filling,
        // clear name+email+role too so they can start fresh. Without this the
        // email stayed populated even after clearing name.
        if (term.length === 0) {
            signers[idx].name = '';
            signers[idx].email = '';
            signers[idx].role = 'Signer';
            signers[idx].suggestions = [];
            signers[idx].showSuggestions = false;
            signers[idx]._autofilled = false;
            this.signers = signers;
            return;
        }

        // Also let the user type into name field if they prefer manual entry
        signers[idx].name = term;
        this.signers = signers;

        // Debounce + fetch suggestions
        clearTimeout(this._searchTimers?.[idx]);
        if (!this._searchTimers) this._searchTimers = {};

        if (term.length < 2) {
            // Clear suggestions
            const s = JSON.parse(JSON.stringify(this.signers));
            s[idx].suggestions = [];
            s[idx].showSuggestions = false;
            this.signers = s;
            return;
        }

        this._searchTimers[idx] = setTimeout(async () => {
            try {
                const results = stripNs(await searchExistingSigners({ searchTerm: term }));
                const s = JSON.parse(JSON.stringify(this.signers));
                // Row may have changed positions; double-check by index
                if (s[idx]) {
                    s[idx].suggestions = results || [];
                    s[idx].showSuggestions = (results || []).length > 0;
                    this.signers = s;
                }
            } catch (err) {
                console.error('Signer search failed:', err);
            }
        }, 300);
    }

    /**
     * Keeps focus in the search box while a suggestion is clicked.
     *
     * preventDefault on mousedown stops the browser moving focus, so no blur
     * fires, so nothing re-renders between mousedown and mouseup and the click
     * lands on the element it started on. Verified against the real DOM: with
     * the re-render in play the click event is never raised at all.
     */
    handleSuggestionMouseDown(e) {
        e.preventDefault();
    }

    handleSignerSuggestionClick(e) {
        const idx = parseInt(e.currentTarget.dataset.index, 10);
        const sIdx = parseInt(e.currentTarget.dataset.sidx, 10);

        const signers = JSON.parse(JSON.stringify(this.signers));
        const pick = signers[idx].suggestions[sIdx];
        if (!pick) return;

        signers[idx].name = pick.name;
        signers[idx].email = pick.email;
        signers[idx].role = pick.role || 'Signer';
        signers[idx].searchTerm = pick.name;
        signers[idx].suggestions = [];
        signers[idx].showSuggestions = false;
        // BUG-005 FIX: mark this row as auto-filled so the search clear handler
        // knows to wipe all fields.
        signers[idx]._autofilled = true;
        this.signers = signers;
    }

    handleSignerSearchBlur(e) {
        // Hide suggestions slightly after blur so click registers first
        const idx = parseInt(e.currentTarget.dataset.index, 10);
        setTimeout(() => {
            const signers = JSON.parse(JSON.stringify(this.signers));
            if (signers[idx]) {
                signers[idx].showSuggestions = false;
                this.signers = signers;
            }
        }, 200);
    }

    handleSignerSearchFocus(e) {
        const idx = parseInt(e.currentTarget.dataset.index, 10);
        const signers = JSON.parse(JSON.stringify(this.signers));
        if (signers[idx] && (signers[idx].suggestions || []).length > 0) {
            signers[idx].showSuggestions = true;
            this.signers = signers;
        }
    }

    /* ── Navigation ── */
    async handleNext() {
        if (this.currentStep === 1) {
            // BUG-002 FIX: reject whitespace-only agreement name
            const trimmedName = (this.agreementName || '').trim();
            if (!trimmedName) {
                this.showToast('Error', 'Agreement name is required', 'error');
                return;
            }
            // Normalize back so server gets the trimmed value
            this.agreementName = trimmedName;

            if (!this.agreementId) {
                this.isLoading = true;
                try {
                    this.agreementId = await createAgreement({
                        name: this.agreementName,
                        agreementType: this.agreementType,
                        signingOrder: this.signingOrder,
                        message: this.message,
                        expiryDate: this.expiryDate || null
                    });
                } catch (e) {
                    this.showToast('Error', e.body?.message || 'Error creating agreement', 'error');
                    this.isLoading = false;
                    return;
                } finally {
                    this.isLoading = false;
                }
            } else {
                // BUG-037/042/043/063 FIX: the record already exists (user came
                // back to Step 1 and edited fields). Previously these edits —
                // name, type, signing order, message, expiry — were never
                // persisted because the create() call only ran on first create.
                // Push the current Step-1 values to the existing record.
                this.isLoading = true;
                try {
                    await updateAgreement({
                        agreementId: this.agreementId,
                        name: this.agreementName,
                        agreementType: this.agreementType,
                        signingOrder: this.signingOrder,
                        message: this.message,
                        expiryDate: this.expiryDate || null
                    });
                } catch (e) {
                    this.showToast('Error', e.body?.message || 'Error updating agreement', 'error');
                    this.isLoading = false;
                    return;
                } finally {
                    this.isLoading = false;
                }
            }
        }
        if (this.currentStep === 2) {
            if (!this.uploadedDoc || this.isUploading) {
                this.showToast('Error',
                    this.isUploading ? 'Upload still in progress…' : 'Please upload a document.',
                    'error');
                return;
            }
        }
        if (this.currentStep === 3) {
            // BUG-002 + BUG-011 FIX: trim + reject blank + validate email format
            const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
            for (const s of this.signers) {
                const nameTrim = (s.name || '').trim();
                const emailTrim = (s.email || '').trim();
                if (!nameTrim) {
                    this.showToast('Error', 'All signers must have a name', 'error');
                    return;
                }
                if (!emailTrim) {
                    this.showToast('Error', 'All signers must have an email', 'error');
                    return;
                }
                if (!emailRe.test(emailTrim)) {
                    this.showToast('Invalid email', `"${emailTrim}" is not a valid email address`, 'error');
                    return;
                }
                s.name = nameTrim;
                s.email = emailTrim;
            }

            // BUG-012 FIX: reject duplicate signer emails (case-insensitive)
            const seenEmails = new Set();
            for (const s of this.signers) {
                const key = s.email.toLowerCase();
                if (seenEmails.has(key)) {
                    this.showToast('Duplicate signer',
                        `${s.email} is added more than once. Each signer must have a unique email.`,
                        'error');
                    return;
                }
                seenEmails.add(key);
            }

            this.isLoading = true;
            try {
                // BUG-008 / BUG-010 / BUG-016 FIX: smart signer sync.
                // Previously the code used a one-shot `signersSaved` flag and just
                // inserted all rows the first time. If the user later went back
                // to Step 3 and added/removed/edited signers, those changes were
                // silently ignored — producing the data-loss bugs where Step 4
                // showed a different count than Step 3.
                //
                // New approach: each row keeps a `serverId` once persisted. On
                // every Next click from Step 3 we diff client state vs server:
                //   - row with serverId + changed fields → updateSigner
                //   - row without serverId            → addSigner, capture serverId
                //   - serverId previously present but row deleted → deleteSigner
                const priorIds = this._savedSignerIds || [];
                const currentIds = [];

                // 1. Insert / update each present row
                for (const s of this.signers) {
                    const orderNum = parseInt(s.order, 10);
                    if (s.serverId) {
                        // Update existing
                        await updateSigner({
                            signerId: s.serverId,
                            signerName: s.name,
                            email: s.email,
                            role: s.role,
                            orderNum: orderNum
                        });
                        currentIds.push(s.serverId);
                    } else {
                        // Insert new
                        const newId = await addSigner({
                            agreementId: this.agreementId,
                            signerName: s.name,
                            email: s.email,
                            role: s.role,
                            orderNum: orderNum
                        });
                        // addSigner currently returns void; capture id by re-querying
                        // would be ideal, but to keep Apex untouched we just mark
                        // a synthetic id so next iteration treats this row as
                        // already-saved. If addSigner is later updated to return
                        // the new Id, this will pick it up automatically.
                        if (newId) {
                            s.serverId = newId;
                            currentIds.push(newId);
                        } else {
                            // Fallback: mark as saved so we don't double-insert
                            s.serverId = 'pending-' + Date.now() + '-' + Math.random();
                        }
                    }
                }

                // 2. Delete any prior server ids that are no longer in the list
                for (const oldId of priorIds) {
                    if (oldId && !oldId.startsWith('pending-')
                        && !currentIds.includes(oldId)) {
                        try {
                            await deleteSigner({ signerId: oldId });
                        } catch (delErr) {
                            console.warn('deleteSigner failed for ' + oldId, delErr);
                        }
                    }
                }

                this._savedSignerIds = currentIds;
                this.signersSaved = true;
            } catch (e) {
                this.showToast('Error', e.body?.message || 'Error saving signers', 'error');
                this.isLoading = false;
                return;
            } finally {
                this.isLoading = false;
            }
        }
        if (this.currentStep === 4) {
            this.isLoading = true;
            try {
                // BUG-004 FIX: flush any debounced field-label/position edits to the
                // server and WAIT for them to commit BEFORE leaving Step 4, so that
                // navigating Back (which destroys + re-fetches the editor) shows the
                // edited labels instead of the stale template values.
                const editor = this.template.querySelector('c-document-editor');
                if (editor && editor.flushPendingSaves) {
                    await editor.flushPendingSaves();
                }
                const count = await getFieldCount({ agreementId: this.agreementId });
                this.fieldsPlaced = count > 0;
            } catch (e) {
                this.fieldsPlaced = false;
            } finally {
                this.isLoading = false;
            }
        }
        this.currentStep++;
    }

    handleBack() {
        // BUG-008 / BUG-010 / BUG-016 FIX: if user navigates back to Step 3
        // from Step 4 (or further), they may add/edit/delete signers. We need
        // to re-sync them with server next time they click Next. Without this,
        // signers in Step 3 didn't propagate to Step 4/5 because of the
        // `signersSaved` flag short-circuit.
        if (this.currentStep === 4 || this.currentStep === 5) {
            this.signersSaved = false;
        }
        this.currentStep--;
    }

    async handleCreateAndSend() {
        if (!this.fieldsPlaced) {
            this.showToast('Error',
                'Cannot send agreement without signature fields. Go back to Step 4 to place fields.',
                'error');
            return;
        }
        this.isLoading = true;
        try {
            await sendForSignature({ agreementId: this.agreementId });
            this.showToast('Success', 'Agreement sent for signature!', 'success');
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: this.agreementId, objectApiName: 'Agreement__c', actionName: 'view' }
            });
        } catch (e) {
            this.showToast('Error', e.body?.message || 'Something went wrong', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleSaveDraft() {
        this.isLoading = true;
        try {
            this.showToast('Saved', 'Agreement saved as Draft. You can add signature fields later.', 'success');
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: this.agreementId, objectApiName: 'Agreement__c', actionName: 'view' }
            });
        } catch (e) {
            this.showToast('Error', e.body?.message || 'Something went wrong', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    /* ── Helpers ── */
    /**
     * Detect the real file type from its first bytes (magic number), so a Word
     * file renamed to .pdf isn't stored as a broken "PDF". Returns:
     *   'pdf'  → starts with %PDF
     *   'zip'  → starts with PK\x03\x04 (DOCX/DOC are ZIP containers)
     *   'unknown' → neither / read failed (caller falls back to the extension)
     */
    sniffMagic(file) {
        return new Promise((resolve) => {
            try {
                const reader = new FileReader();
                reader.onload = () => {
                    const b = new Uint8Array(reader.result);
                    if (b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46) resolve('pdf');
                    else if (b[0] === 0x50 && b[1] === 0x4B && b[2] === 0x03 && b[3] === 0x04) resolve('zip');
                    else resolve('unknown');
                };
                reader.onerror = () => resolve('unknown');
                reader.readAsArrayBuffer(file.slice(0, 5));
            } catch (e) {
                resolve('unknown');
            }
        });
    }
    fileToBase64(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(reader.result.split(',')[1]);
            reader.onerror = () => reject(new Error('FileReader failed'));
            reader.readAsDataURL(file);
        });
    }
    blobToBase64(blob) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(reader.result.split(',')[1]);
            reader.onerror = () => reject(new Error('FileReader failed'));
            reader.readAsDataURL(blob);
        });
    }
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
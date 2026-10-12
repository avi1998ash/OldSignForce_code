import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import USER_NAME from '@salesforce/schema/User.Name';
import USER_ID from '@salesforce/user/Id';
import { getRecord } from 'lightning/uiRecordApi';

import { friendlyError } from 'c/signforceErrors';
import listGenerationsForRecord from '@salesforce/apex/DocumentHistoryController.listGenerationsForRecord';
import resolveRecipientEmail from '@salesforce/apex/DocumentHistoryController.resolveRecipientEmail';
import sendDocumentEmail from '@salesforce/apex/DocumentHistoryController.sendDocumentEmail';
import regenerateFromHistory from '@salesforce/apex/DocumentHistoryController.regenerateFromHistory';
import deleteGeneratedDocument from '@salesforce/apex/DocumentHistoryController.deleteGeneratedDocument';
// New: promote a "file-only" history row to a proper Agreement record.
// Used when the user generated the doc without Auto_Create_Agreement on
// the template and now wants to turn it into an agreement.
import createAgreementFromHistory from '@salesforce/apex/DocumentHistoryController.createAgreementFromHistory';
// Re-render an orphan auto-create row's document on demand (no persistence).
// Used by "Open File" when the row has no contentDocumentId but was a
// successful auto-create generation — we re-run Lambda to get fresh bytes
// and show them in the preview modal without creating an Agreement.
import regenerateForPreview from '@salesforce/apex/DocumentHistoryController.regenerateForPreview';
// Convert a non-PDF ContentVersion (DOCX/DOC) to PDF via Lambda — used
// when previewing Word documents in the modal because PDFPreview.page
// can only render PDFs natively. Returns S3 presigned URL.
import getPreviewUrlForContentVersion from '@salesforce/apex/DocumentHistoryController.getPreviewUrlForContentVersion';
import { stripNs, vfPageUrl } from 'c/nsUtils';

/**
 * documentGenerationHistory — record-page tile listing generated documents.
 *
 * Drops onto Account, Contact, Opportunity, Lead, etc. via App Builder.
 * Reads recordId from page context, queries Document_Generation_Log__c via
 * the Apex controller, and renders rows with Open / Send Email / Re-generate /
 * Delete actions.
 */
export default class DocumentGenerationHistory extends NavigationMixin(LightningElement) {
    @api recordId;

    /* Rows per page. Settable per placement in App Builder; anything unusable
       (blank, zero, not a number) falls back to this default. */
    @api pageSize = 3;

    @track rawRows = [];
    @track isLoading = true;
    @track includeFailed = false;
    @track pageNumber = 1;

    // Action state
    @track isProcessing = false;
    /* Raised only while a document is actually being rebuilt, so the overlay
       appears for that and for nothing else on this card. */
    @track isRegenerating = false;
    @track isCreatingAgreement = false;
    @track deleteConfirmId = null;
    @track deleteConfirmAgreementId = null;   // linked agreement to cascade-delete
    @track deleteConfirmAgreementName = '';
    // STEP-2 signer mapping collected before creating an agreement, as the JSON
    // string materializeSignersAndFieldsMapped expects. Null means "use the
    // template's own signer emails unchanged".
    _pendingSignerMapping = null;
    _pendingRow = null;
    @track showSignerMapModal = false;
    @track signerMapTemplateId = null;
    @track emailModalRow = null;
    @track emailTo = '';
    @track emailSubject = '';
    @track emailBody = '';

    // File preview modal state.
    // showPreviewModal toggles the modal; previewUrl is the iframe src
    // (PDFPreview.page handles both PDF and DOCX rendering); previewFileName
    // is shown in the header; previewDownloadUrl is the direct file servlet
    // link for the "Download" footer button.
    @track showPreviewModal = false;
    @track previewLoading = false;
    @track previewUrl = '';
    @track previewFileName = '';
    @track previewDownloadUrl = '';

    // Wire handle for refreshApex
    _wiredHistory;

    // Cached current user name (used for default email signature)
    @track currentUserName = '';

    @wire(getRecord, { recordId: USER_ID, fields: [USER_NAME] })
    wiredUser({ data }) {
        if (data && data.fields && data.fields.Name) {
            this.currentUserName = data.fields.Name.value || '';
        }
    }

    @wire(listGenerationsForRecord, { recordId: '$recordId', includeFailed: '$includeFailed' })
    wiredHistory(result) {
        this._wiredHistory = result;
        if (result.data) {
            this.rawRows = stripNs(result.data);
            // The list can shrink under the reader — deleting the only row on the
            // last page, or switching "Show failed" off. Without this the user is
            // left staring at a page that no longer has anything on it.
            this.clampPage();
            this.isLoading = false;
        } else if (result.error) {
            console.error('listGenerationsForRecord failed', result.error);
            this.toast('Error',
                'Could not load generation history: ' + this.errMsg(result.error), 'error');
            this.isLoading = false;
        }
    }

    /* ── Computed ────────────────────────────────────────────────── */

    get showEmpty() { return !this.isLoading && this.rawRows.length === 0; }
    get showRows() { return !this.isLoading && this.rawRows.length > 0; }

    /* ── Pagination ──────────────────────────────────────────────── */

    /** App Builder hands numbers back as strings, and can hand back nothing. */
    get rowsPerPage() {
        const n = parseInt(this.pageSize, 10);
        return Number.isFinite(n) && n > 0 ? n : 5;
    }

    get totalPages() {
        return Math.max(1, Math.ceil(this.rawRows.length / this.rowsPerPage));
    }

    /** Only the current page's rows are formatted — no work on rows nobody sees. */
    get rows() {
        const start = (this.pageNumber - 1) * this.rowsPerPage;
        return this.rawRows
            .slice(start, start + this.rowsPerPage)
            .map(r => this.formatRow(r));
    }

    /* The count is always worth showing — it tells you how much history this
       record has. The Previous/Next controls are not: on a single page they
       would sit there permanently disabled. */
    get showFooter() {
        return !this.isLoading && this.rawRows.length > 0;
    }

    get showPagination() {
        return this.showFooter && this.rawRows.length > this.rowsPerPage;
    }

    get rangeLabel() {
        const total = this.rawRows.length;
        if (!total) return '';
        // One page: a plain count reads better than "1-1 of 1".
        if (total <= this.rowsPerPage) {
            return total === 1 ? '1 document' : `${total} documents`;
        }
        const from = (this.pageNumber - 1) * this.rowsPerPage + 1;
        const to = Math.min(from + this.rowsPerPage - 1, total);
        return `${from}-${to} of ${total}`;
    }

    get pageLabel() { return `Page ${this.pageNumber} of ${this.totalPages}`; }
    get isFirstPage() { return this.pageNumber <= 1; }
    get isLastPage() { return this.pageNumber >= this.totalPages; }

    /* Keeps pageNumber inside the range the data actually supports. Called
       whenever rawRows changes — never from a getter, which would mutate state
       during render. */
    clampPage() {
        const max = this.totalPages;
        if (this.pageNumber > max) this.pageNumber = max;
        if (this.pageNumber < 1) this.pageNumber = 1;
    }

    handlePrevPage() {
        if (!this.isFirstPage) this.pageNumber -= 1;
    }

    handleNextPage() {
        if (!this.isLastPage) this.pageNumber += 1;
    }

    formatRow(r) {
        const isSuccess = r.status === 'Success';
        const hasFile = !!r.contentDocumentId;
        const hasAgreement = !!r.agreementId;

        // Open Agreement: appears when the row is linked to an agreement.
        const canOpenAgreement = isSuccess && hasAgreement;

        // Open File: shown on EVERY successful row. Two paths:
        //   (a) Row already has contentDocumentId → open the existing file
        //       in the preview modal directly (instant).
        //   (b) Orphan auto-create row (no file, no agreement, but was
        //       successful) → on click, re-render via Lambda first then
        //       show the freshly generated bytes in the modal. The handler
        //       (handleOpenFile) decides which path to take.
        const canOpenFile = isSuccess && (hasFile || !!r.wasAutoCreate);

        const canEmail = isSuccess && (hasFile || hasAgreement);
        // Show "Generate Agreement" when:
        //   (a) Row has a file but no agreement (typical non-auto-create
        //       template — file lives on source record, user can promote
        //       it to an agreement)
        //   (b) Row was an auto-create generation that ended up orphaned
        //       (no file AND no agreement linked — e.g. another log already
        //       claimed the only existing agreement). Server flags these
        //       with wasAutoCreate=true so we offer Generate Agreement to
        //       re-render + create fresh.
        const canGenerateAgreement = isSuccess && !hasAgreement && (hasFile || !!r.wasAutoCreate);

        let statusBadgeClass = 'sf-status-badge';
        if (r.status === 'Success') statusBadgeClass += ' sf-status-success';
        else if (r.status === 'Failure') statusBadgeClass += ' sf-status-failure';
        else statusBadgeClass += ' sf-status-progress';

        let cardClass = 'sf-row-card';
        if (r.status === 'Failure') cardClass += ' sf-row-card-failure';

        // A failed row's message is whatever the renderer threw — for a broken
        // template that is a full docxtemplater stack trace. Show the person
        // what to do; keep the raw text one click away for an admin.
        const hasError = r.status === 'Failure' && !!r.errorMessage;
        const fe = hasError ? friendlyError(r.errorMessage) : null;

        return {
            ...r,
            relativeDate: this.relativeTime(r.createdDate),
            hasError,
            errorTitle: fe ? fe.title : '',
            errorMessage: fe ? fe.text : r.errorMessage,
            errorDetail: fe ? fe.detail : '',
            statusBadgeClass,
            cardClass,
            canOpenAgreement,
            canOpenFile,
            canEmail,
            canGenerateAgreement
        };
    }

    /* ── Header actions ─────────────────────────────────────────── */

    handleToggleFailed(e) {
        this.includeFailed = e.target.checked;
        // Different list, so start at the top of it rather than on whatever
        // page number happened to be showing.
        this.pageNumber = 1;
        this.isLoading = true;
        // includeFailed change auto-rewires; no need to call refreshApex here
    }

    handleRefresh() {
        this.isLoading = true;
        refreshApex(this._wiredHistory).finally(() => {
            this.isLoading = false;
        });
    }

    /* ── Per-row actions ────────────────────────────────────────── */

    handleRowAction(e) {
        const logId = e.currentTarget.dataset.id;
        const action = e.currentTarget.dataset.action;
        const row = this.rawRows.find(r => r.logId === logId);
        if (!row) return;

        switch (action) {
            // Split into 2 distinct actions:
            //   openAgreement → navigate to Agreement record page
            //   openFile      → show preview modal (stays in this component)
            case 'openAgreement': this.handleOpenAgreement(row); break;
            case 'openFile': this.handleOpenFile(row); break;
            case 'email': this.openEmailModal(row); break;
            case 'regenerate': this.handleRegenerate(row); break;
            case 'delete':
                this.deleteConfirmId = logId;
                this.deleteConfirmAgreementId = row.agreementId || null;
                this.deleteConfirmAgreementName = row.agreementName || '';
                break;
            case 'generateAgreement': this.handleGenerateAgreement(row); break;
            default: break;
        }
    }

    /**
     * Navigate to the linked Agreement__c record page.
     * Called by the "Open Agreement" button (only visible when row.agreementId exists).
     */
    handleOpenAgreement(row) {
        if (!row.agreementId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: row.agreementId,
                objectApiName: 'Agreement__c',
                actionName: 'view'
            }
        });
    }

    /**
     * Show the generated file inline in a modal preview.
     * Uses /apex/PDFPreview?cvId=... — same pattern as agreementDocumentUpload
     * LWC. Relative URL is LWS-safe (data: and blob: URLs are blocked by
     * Lightning Web Security in iframe.src).
     *
     * Two paths:
     *   Path A — Row has contentVersionId → load existing file via PDFPreview
     *   Path B — Orphan auto-create row → server re-renders + saves a
     *            ContentVersion (silently), returns its cvId, we use it
     *            same way as Path A.
     */
    async handleOpenFile(row) {
        this.previewFileName = row.filename || 'Generated document';
        this.previewLoading = true;
        this.previewUrl = '';
        this.previewDownloadUrl = '';
        this.showPreviewModal = true;

        // Decide preview strategy based on file type.
        //   PDF  → PDFPreview.page accepts cvId directly (no Lambda call).
        //   DOCX/DOC → PDFPreview can't render Word files ("Invalid PDF
        //              structure" error). Have to convert to PDF via
        //              Lambda first, then iframe loads PDFPreview wrapping
        //              the S3 URL.
        // We read fileExtension off the row (resolved server-side).
        // Fallback heuristic: check filename suffix when extension missing.
        const ext = (row.fileExtension || '').toLowerCase();
        const fname = (row.filename || '').toLowerCase();
        const isPdf = ext === 'pdf' || (!ext && fname.endsWith('.pdf'));
        const isWord = ext === 'docx' || ext === 'doc'
            || (!ext && (fname.endsWith('.docx') || fname.endsWith('.doc')));

        // ───────────── Path A: existing file ─────────────
        if (row.contentVersionId) {
            // Always populate the Download button to a direct file servlet —
            // works for any file type and respects sharing.
            this.previewDownloadUrl = '/sfc/servlet.shepherd/document/download/'
                + row.contentDocumentId;

            if (isPdf) {
                // PDF — direct PDFPreview, no Lambda needed.
                this.previewUrl = vfPageUrl('PDFPreview') + '?cvId='
                    + encodeURIComponent(row.contentVersionId)
                    + '&ts=' + Date.now();
                setTimeout(() => { this.previewLoading = false; }, 4000);
                return;
            }

            if (isWord) {
                // DOCX/DOC — convert via Lambda, wrap result in PDFPreview.
                try {
                    const pdfUrl = await getPreviewUrlForContentVersion({
                        contentVersionId: row.contentVersionId
                    });
                    if (!pdfUrl) throw new Error('No URL returned');
                    this.previewUrl = vfPageUrl('PDFPreview') + '?pdfUrl='
                        + encodeURIComponent(pdfUrl)
                        + '&ts=' + Date.now();
                } catch (err) {
                    this.previewLoading = false;
                    this.showPreviewModal = false;
                    this.toast('Could not load preview', this.errMsg(err), 'error');
                    return;
                }
                setTimeout(() => { this.previewLoading = false; }, 4000);
                return;
            }

            // Unknown extension — try direct route as best-effort.
            this.previewUrl = vfPageUrl('PDFPreview') + '?cvId='
                + encodeURIComponent(row.contentVersionId)
                + '&ts=' + Date.now();
            setTimeout(() => { this.previewLoading = false; }, 4000);
            return;
        }

        // ───────────── Path B: orphan — re-render + persist + preview ─────────────
        // Lightning Web Security blocks blob: and data: URLs in iframe.src,
        // so we can't preview Lambda-returned bytes directly. Server-side
        // method renders + persists a ContentVersion, returns the cvId,
        // and we use the same PDFPreview route as Path A. Orphan re-renders
        // produce DOCX (template output format) so we route through Lambda
        // conversion just like the regular Word path above.
        let regenerated;
        try {
            regenerated = await regenerateForPreview({ logId: row.logId });
            if (!regenerated || !regenerated.contentVersionId) {
                throw new Error('Server did not return a preview file');
            }
            this.previewFileName = regenerated.filename || this.previewFileName;
            this.previewDownloadUrl = regenerated.contentDocumentId
                ? '/sfc/servlet.shepherd/document/download/' + regenerated.contentDocumentId
                : '';
        } catch (err) {
            this.previewLoading = false;
            this.showPreviewModal = false;
            this.toast('Could not load preview', this.errMsg(err), 'error');
            return;
        }

        // Detect format of regenerated file (server returns filename in result).
        const rfname = (regenerated.filename || '').toLowerCase();
        const regenIsPdf = rfname.endsWith('.pdf');

        if (regenIsPdf) {
            this.previewUrl = vfPageUrl('PDFPreview') + '?cvId='
                + encodeURIComponent(regenerated.contentVersionId)
                + '&ts=' + Date.now();
        } else {
            // DOCX regen — convert via Lambda before previewing
            try {
                const pdfUrl = await getPreviewUrlForContentVersion({
                    contentVersionId: regenerated.contentVersionId
                });
                if (!pdfUrl) throw new Error('No URL returned');
                this.previewUrl = vfPageUrl('PDFPreview') + '?pdfUrl='
                    + encodeURIComponent(pdfUrl)
                    + '&ts=' + Date.now();
            } catch (err) {
                this.previewLoading = false;
                this.showPreviewModal = false;
                this.toast('Could not load preview', this.errMsg(err), 'error');
                return;
            }
        }

        // The row that came through here had no file id, so the server had to
        // resolve (or render) one and stamp it on the log. Refresh so this row now
        // carries it and the next Open File takes the direct path instead of
        // resolving again. Cosmetic — a failure only costs one extra lookup.
        try { await refreshApex(this._wiredHistory); } catch (e) { /* not worth surfacing */ }

        setTimeout(() => { this.previewLoading = false; }, 4000);
    }

    /**
     * Iframe finished loading the preview — hide the spinner.
     */
    handlePreviewLoaded() {
        this.previewLoading = false;
    }

    /**
     * Close + reset preview modal state.
     */
    closePreview() {
        this.showPreviewModal = false;
        this.previewUrl = '';
        this.previewFileName = '';
        this.previewDownloadUrl = '';
        this.previewLoading = false;
    }

    async handleRegenerate(row) {
        this.isProcessing = true;
        // Its own flag, not isProcessing: that one is also raised by delete and
        // by email, and "Building your document" over a delete would be a lie.
        this.isRegenerating = true;
        try {
            const r = await regenerateFromHistory({ logId: row.logId });
            if (r && r.status === 'Success') {
                this.toast('Re-generated', r.filename, 'success');
                await refreshApex(this._wiredHistory);
            } else {
                const msg = (r && r.errorMessage) || 'Unknown error';
                this.toast('Re-generation failed', msg, 'error');
            }
        } catch (err) {
            this.toast('Re-generation failed', this.errMsg(err), 'error');
        } finally {
            this.isProcessing = false;
            this.isRegenerating = false;
        }
    }

    /**
     * Promote a file-only history row to a full Agreement record.
     * The server-side method creates Agreement__c (Draft), copies the
     * existing generated file into it as the Original document, and tags
     * the agreement back to the source record so the existing-drafts
     * lookup picks it up on future generations.
     *
     * After success, we refresh the history so the row instantly shows
     * "Open Agreement" instead of "Generate Agreement", and navigate
     * to the new agreement.
     */
    /**
     * Opens the signer-mapping dialog first. The template may define signers, or
     * leave fields without one, and both have to resolve to a real email before
     * the agreement exists — otherwise it arrives with no recipients.
     *
     * The dialog is mounted optimistically: the mapper loads the template layout
     * and reports through `ready` whether there is anything to map, and
     * handleMapperReady closes it and proceeds when there is not. That keeps
     * templates with no signers behaving exactly as before, with no extra click.
     */
    handleGenerateAgreement(row) {
        this._pendingRow = row;
        this._pendingSignerMapping = null;
        this.signerMapTemplateId = row.templateId || null;
        if (!this.signerMapTemplateId) {
            // No template on the log — nothing could be mapped anyway.
            this.createAgreementNow(row);
            return;
        }
        this.showSignerMapModal = true;
    }

    /** Nothing to map → skip the dialog entirely and create the agreement. */
    handleMapperReady(event) {
        if (event.detail && event.detail.hasRows) return;
        this.showSignerMapModal = false;
        const row = this._pendingRow;
        if (row) this.createAgreementNow(row);
    }

    cancelSignerMap() {
        if (this.isProcessing) return;
        this.showSignerMapModal = false;
        this.signerMapTemplateId = null;
        this._pendingRow = null;
    }

    confirmSignerMap() {
        const mapper = this.template.querySelector('c-template-signer-mapper');
        if (mapper) {
            const problem = mapper.validate();
            if (problem) {
                this.toast('Check the signer emails', problem, 'error');
                return;
            }
            this._pendingSignerMapping = JSON.stringify(mapper.buildMapping());
        }
        this.showSignerMapModal = false;
        if (this._pendingRow) this.createAgreementNow(this._pendingRow);
    }

    async createAgreementNow(row) {
        this.isProcessing = true;
        // Full-card loader, same treatment as isRegenerating: the button-disable
        // alone reads as a dead click while the server copies the document.
        this.isCreatingAgreement = true;
        try {
            const newAgreementId = await createAgreementFromHistory({
                logId: row.logId,
                mappingJson: this._pendingSignerMapping || null
            });
            if (!newAgreementId) {
                this.toast('Failed', 'Agreement could not be created', 'error');
                return;
            }
            this.toast('Agreement created', row.filename || 'Draft agreement ready', 'success');
            // Refresh history so the row flips from "Generate Agreement"
            // to "Open Agreement". Then navigate to the new record.
            await refreshApex(this._wiredHistory);
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: newAgreementId,
                    objectApiName: 'Agreement__c',
                    actionName: 'view'
                }
            });
        } catch (err) {
            this.toast('Could not create agreement', this.errMsg(err), 'error');
        } finally {
            this.isProcessing = false;
            this.isCreatingAgreement = false;
            this._pendingRow = null;
            this._pendingSignerMapping = null;
            this.signerMapTemplateId = null;
        }
    }

    /* ── Delete flow ────────────────────────────────────────────── */

    cancelDelete() {
        this.deleteConfirmId = null;
        this.deleteConfirmAgreementId = null;
        this.deleteConfirmAgreementName = '';
    }

    get deleteHasAgreement() {
        return !!this.deleteConfirmAgreementId;
    }

    async confirmDelete() {
        if (!this.deleteConfirmId) return;
        const hadAgreement = !!this.deleteConfirmAgreementId;
        this.isProcessing = true;
        try {
            await deleteGeneratedDocument({
                logId: this.deleteConfirmId,
                agreementId: this.deleteConfirmAgreementId
            });
            this.toast(
                'Deleted',
                hadAgreement
                    ? 'Document and its agreement (signers, fields and files) removed.'
                    : 'Document removed.',
                'success'
            );
            this.cancelDelete();
            await refreshApex(this._wiredHistory);
        } catch (err) {
            this.toast('Delete failed', this.errMsg(err), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    /* ── Email flow ─────────────────────────────────────────────── */

    async openEmailModal(row) {
        this.emailModalRow = row;
        this.emailSubject = `Document: ${row.filename}`;
        this.emailBody = this.buildDefaultBody(row);
        this.emailTo = '';

        // Try to resolve a default recipient from the source record
        try {
            const addr = await resolveRecipientEmail({ recordId: this.recordId });
            this.emailTo = addr || '';
        } catch (e) {
            // Non-fatal — user can type the address manually
            this.emailTo = '';
        }
    }

    cancelEmail() {
        if (this.isProcessing) return;
        this.emailModalRow = null;
        this.emailTo = '';
        this.emailSubject = '';
        this.emailBody = '';
    }

    handleEmailToChange(e) { this.emailTo = e.target.value; }
    handleEmailSubjectChange(e) { this.emailSubject = e.target.value; }
    handleEmailBodyChange(e) { this.emailBody = e.target.value; }

    async confirmSendEmail() {
        if (!this.emailModalRow) return;
        const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        if (!this.emailTo || !emailRe.test(this.emailTo)) {
            const input = this.template.querySelector('lightning-input[type="email"]');
            if (input) input.reportValidity();
            this.toast('Invalid email', 'Please enter a valid recipient email address', 'warning');
            return;
        }
        this.isProcessing = true;
        try {
            await sendDocumentEmail({
                logId: this.emailModalRow.logId,
                toAddress: this.emailTo,
                subject: this.emailSubject,
                body: this.emailBody
            });
            this.toast('Email sent', `Sent to ${this.emailTo}`, 'success');
            this.emailModalRow = null;
            this.emailTo = '';
            this.emailSubject = '';
            this.emailBody = '';
        } catch (err) {
            this.toast('Email failed', this.errMsg(err), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    buildDefaultBody(row) {
        const sender = this.currentUserName || 'the team';
        return `Hi,\n\nPlease find the attached document "${row.filename}". Let me know if you have any questions.\n\nThanks,\n${sender}`;
    }

    /* ── Helpers ────────────────────────────────────────────────── */

    stopPropagation(e) { e.stopPropagation(); }

    relativeTime(iso) {
        if (!iso) return '';
        const then = new Date(iso);
        const ms = Date.now() - then.getTime();
        if (isNaN(ms)) return '';
        const sec = Math.round(ms / 1000);
        if (sec < 60) return sec <= 5 ? 'Just now' : `${sec} seconds ago`;
        const min = Math.round(sec / 60);
        if (min < 60) return min === 1 ? '1 minute ago' : `${min} minutes ago`;
        const hr = Math.round(min / 60);
        if (hr < 24) return hr === 1 ? '1 hour ago' : `${hr} hours ago`;
        const day = Math.round(hr / 24);
        if (day < 30) return day === 1 ? 'Yesterday' : `${day} days ago`;
        return then.toLocaleDateString();
    }

    errMsg(err) {
        if (!err) return 'Unknown error';
        return err?.body?.message || err?.message || JSON.stringify(err);
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
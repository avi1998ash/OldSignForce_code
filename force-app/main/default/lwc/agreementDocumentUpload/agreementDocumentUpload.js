import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
// Converts a Word ContentVersion to PDF via Lambda and returns an S3 URL —
// needed because PDFPreview can only render PDFs ('Invalid PDF structure' on DOCX).
import getPreviewUrlForContentVersion from '@salesforce/apex/DocumentHistoryController.getPreviewUrlForContentVersion';
import { refreshApex } from '@salesforce/apex';
// BUG-036 FIX: need agreement status to show/hide the re-upload UI.
// Only Draft agreements should allow uploading replacement docs.
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import STATUS_FIELD from '@salesforce/schema/Agreement__c.Status__c';
import getAgreementDocuments from '@salesforce/apex/DocumentService.getAgreementDocuments';
import linkDocumentToAgreement from '@salesforce/apex/DocumentService.linkDocumentToAgreement';
import deleteAgreementDocument from '@salesforce/apex/DocumentService.deleteAgreementDocument';
import getDocumentDownloadUrl from '@salesforce/apex/DocumentService.getDocumentDownloadUrl';
// BUG-024: lightning-file-upload uploads before any client-side size check is
// possible, so we validate the ContentVersion size AFTER upload and remove
// over-size files instead of linking them.
import getContentVersionSize from '@salesforce/apex/DocumentService.getContentVersionSize';
import deleteContentDocument from '@salesforce/apex/DocumentService.deleteContentDocument';
// Cloud (>4MB Drive/OneDrive) docs have no ContentVersion and no S3 presigned
// URL — their bytes are proxied in chunks through Apex -> Lambda.
import getCloudDocChunk from '@salesforce/apex/AgreementController.getCloudDocChunk';
import { stripNs, vfPageUrl } from 'c/nsUtils';

// BUG-024: 20 MB upload ceiling for the record-page Documents upload.
const MAX_FILE_SIZE_BYTES = 20 * 1024 * 1024;

export default class AgreementDocumentUpload extends NavigationMixin(LightningElement) {

    // Documents are attached through the Create Agreement flow, not from this
    // card — the empty state sends the user there. Packaged tabs carry the
    // namespace in their runtime api name in every org.
    handleGoToCreateAgreement() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Create_Agreement' }
        });
    }
    @api recordId;
    @track isLoading = false;
    @track showPreviewModal = false;
    @track previewUrl = '';
    @track previewDocName = '';
    @track previewDownloadUrl = '';     // direct URL for the modal Download button
    wiredDocsResult;

    // BUG-036 FIX: wire the Status field so we can gate the upload button.
    @wire(getRecord, { recordId: '$recordId', fields: [STATUS_FIELD] })
    wiredAgreement;

    get agreementStatus() {
        return this.wiredAgreement?.data ? getFieldValue(this.wiredAgreement.data, STATUS_FIELD) : null;
    }

    // BUG-036 FIX: Upload control only renders when agreement is Draft.
    // Sent/Completed/Voided agreements shouldn't allow replacing the doc
    // (would invalidate signatures already collected).
    get canUpload() {
        return this.agreementStatus === 'Draft';
    }

    // BUG-036 FIX: original Original-doc record types only (Signer can't
    // reupload Stamped/Signed). The accepted file types match the
    // standard agreement upload (PDF + Word).
    get uploadAcceptedFormats() {
        return ['.pdf', '.doc', '.docx'];
    }

    // When a file misses the accept list, lightning-file-upload emits its own
    // "Your company doesn't support the following file types" message. That text
    // belongs to the platform and can't be reworded, and it is misleading here —
    // the restriction is eSignforce's, not the customer's org configuration. So
    // state the rule up front instead, and build the list from
    // uploadAcceptedFormats / MAX_FILE_SIZE_BYTES so the hint cannot drift away
    // from what the uploader will actually take.
    get uploadHint() {
        return 'eSignforce accepts ' + this.uploadAcceptedFormats.join(', ') +
            ' only. Max ' + (MAX_FILE_SIZE_BYTES / (1024 * 1024)) + ' MB.';
    }

    @wire(getAgreementDocuments, { agreementId: '$recordId' })
    wiredDocs(result) {
        this.wiredDocsResult = result;
    }

    get documents() {
        if (!this.wiredDocsResult?.data) return [];
        return stripNs(this.wiredDocsResult.data).map(doc => {
            const type = doc.documentType || 'Original';
            const name = (doc.Name || '').toLowerCase();
            const fileType = (doc.fileType || '').toLowerCase();
            const isPdf = fileType === 'pdf' || name.endsWith('.pdf');
            const isWord = fileType === 'word' || fileType === 'word_x' || name.endsWith('.doc') || name.endsWith('.docx');
            // Cloud docs may ALSO carry a share link in s3PreviewUrl (the Drive
            // link stored at stamp time), so check Cloud first — that link is an
            // HTML viewer page, not a raw PDF, and must not go to pdf.js.
            const isCloud = doc.storageType === 'Cloud' && !!doc.cloudFileId;
            const isS3 = !isCloud && !!doc.s3PreviewUrl;

            // Icon
            let icon = 'doctype:unknown';
            let iconBgClass = 'doc-icon-pdf';
            if (isPdf) {
                icon = 'doctype:pdf';
                iconBgClass = 'doc-icon-pdf';
            } else if (isWord) {
                icon = 'doctype:word';
                iconBgClass = 'doc-icon-word';
            }
            if (type === 'Signed') iconBgClass = 'doc-icon-signed';
            else if (type === 'Stamped') iconBgClass = 'doc-icon-stamped';

            let typeBadgeClass = 'type-badge-original';
            if (type === 'Signed') typeBadgeClass = 'type-badge-signed';
            else if (type === 'Stamped') typeBadgeClass = 'type-badge-stamped';

            // The stored Document_Type__c values read oddly to a user: the fully
            // executed document is 'Stamped' (how it was produced) and the audit
            // certificate is 'Signed'. Label them by what they ARE instead. The
            // underlying values are untouched — every query still filters on them.
            let typeLabel = type;
            if (type === 'Stamped') typeLabel = 'Signed';
            else if (type === 'Signed') typeLabel = 'Certificate Of Completion';

            // The bug fix: pre-resolve the URL each row needs for preview & download.
            // S3 docs (Tier2/Tier3) — use the stored presigned URL directly.
            // Tier1 docs — use the ContentVersion download servlet.
            const accessUrl = isS3
                ? doc.s3PreviewUrl
                : (doc.contentVersionId ? '/sfc/servlet.shepherd/version/download/' + doc.contentVersionId : '');

            return {
                ...doc,
                icon,
                iconBgClass,
                typeBadgeClass,
                typeLabel,
                // Cloud rows carry no direct URL — preview/download go through the
                // chunked Lambda proxy keyed by the document id instead.
                accessUrl: isCloud ? (doc.s3PreviewUrl || '') : accessUrl,
                cloudFlag: isCloud ? '1' : ''
            };
        });
    }

    async handleUploadFinished(event) {
        this.isLoading = true;
        try {
            const uploadedFiles = event.detail.files;
            let linkedCount = 0;
            let rejectedOversize = false;
            for (const file of uploadedFiles) {
                // BUG-024: lightning-file-upload has already uploaded the file,
                // so check its size now and reject (delete) anything over 20 MB
                // instead of linking it to the agreement.
                const size = await getContentVersionSize({ contentDocumentId: file.documentId });
                if (size > MAX_FILE_SIZE_BYTES) {
                    rejectedOversize = true;
                    await deleteContentDocument({ contentDocumentId: file.documentId });
                    continue;
                }
                await linkDocumentToAgreement({
                    agreementId: this.recordId,
                    contentDocumentId: file.documentId,
                    documentType: 'Original'
                });
                linkedCount++;
            }
            await refreshApex(this.wiredDocsResult);
            if (rejectedOversize) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Error',
                    message: 'File exceeds 20 MB',
                    variant: 'error'
                }));
            }
            if (linkedCount > 0) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Success',
                    message: 'Document uploaded successfully!',
                    variant: 'success'
                }));
            }
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error',
                message: e.body?.message || 'Upload failed',
                variant: 'error'
            }));
        } finally {
            this.isLoading = false;
        }
    }

    async handleDelete(event) {
        const docId = event.currentTarget.dataset.id;
        const ok = await this.template.querySelector('c-signforce-confirm').open({
            title: 'Delete this document?',
            message: 'It will be removed from the agreement. This cannot be undone.',
            confirmLabel: 'Delete',
            variant: 'danger'
        });
        if (!ok) return;
        this.isLoading = true;
        try {
            await deleteAgreementDocument({ documentId: docId });
            await refreshApex(this.wiredDocsResult);
            this.dispatchEvent(new ShowToastEvent({
                title: 'Deleted',
                message: 'Document removed.',
                variant: 'success'
            }));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error',
                message: 'Delete failed.',
                variant: 'error'
            }));
        } finally {
            this.isLoading = false;
        }
    }

    async handleDownload(event) {
        const url = event.currentTarget.dataset.url;
        const isCloud = event.currentTarget.dataset.cloud === '1';
        const docId = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name || 'document.pdf';

        if (isCloud) {
            // Prefer the provider share link (stamped docs have one); otherwise
            // pull the bytes through the Lambda proxy and save them as a blob.
            if (url) { window.open(url, '_blank'); return; }
            this.isLoading = true;
            try {
                const base64 = await this._fetchCloudBase64(docId);
                if (!base64) throw new Error('Empty document');
                this._saveBase64AsFile(base64, name);
            } catch (e) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Error', message: 'Cloud download failed.', variant: 'error'
                }));
            } finally {
                this.isLoading = false;
            }
            return;
        }

        if (!url) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error', message: 'No download URL for this document.', variant: 'error'
            }));
            return;
        }
        window.open(url, '_blank');
    }

    async handlePreview(event) {
        const url = event.currentTarget.dataset.url;
        const name = event.currentTarget.dataset.name;
        const isCloud = event.currentTarget.dataset.cloud === '1';
        const docId = event.currentTarget.dataset.id;

        if (isCloud) {
            // Cloud doc: PDFPreview in receive mode; bytes are posted into the
            // iframe once it loads (handleFrameLoad) — same flow as documentEditor.
            this.previewDocName = name;
            this.previewDownloadUrl = url || '';
            this._pendingCloudDocId = docId;
            this.previewUrl = vfPageUrl('PDFPreview') + '?mode=receive&ts=' + Date.now();
            this.showPreviewModal = true;
            return;
        }

        if (!url) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error', message: 'No preview URL for this document.', variant: 'error'
            }));
            return;
        }
        this.previewDocName = name;
        this.previewDownloadUrl = url;
        this.previewUrl = '';
        this.showPreviewModal = true;

        // PDFPreview.page accepts either cvId (Salesforce file) or pdfUrl (any
        // accessible URL — including S3 presigned). Detect by URL shape.
        if (url.startsWith('http')) {
            this.previewUrl = vfPageUrl('PDFPreview') + '?pdfUrl=' + encodeURIComponent(url) + '&ts=' + Date.now();
            return;
        }

        // /sfc/servlet.shepherd/version/download/{cvId}
        const cvId = url.split('/').pop();

        // Word files can't render in the PDF previewer ("Invalid PDF structure").
        // Convert them to PDF via Lambda first, then preview the converted PDF —
        // same approach as documentGenerationHistory / generateDocument.
        const lowerName = (name || '').toLowerCase();
        const isWord = lowerName.endsWith('.docx') || lowerName.endsWith('.doc');
        if (isWord) {
            try {
                const pdfUrl = await getPreviewUrlForContentVersion({ contentVersionId: cvId });
                if (!pdfUrl) throw new Error('No URL returned');
                this.previewUrl = vfPageUrl('PDFPreview') + '?pdfUrl=' + encodeURIComponent(pdfUrl) + '&ts=' + Date.now();
            } catch (err) {
                this.showPreviewModal = false;
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Could not load preview',
                    message: (err && err.body && err.body.message) || (err && err.message) || 'Conversion failed',
                    variant: 'error'
                }));
            }
            return;
        }

        this.previewUrl = vfPageUrl('PDFPreview') + '?cvId=' + cvId + '&ts=' + Date.now();
    }

    /** Iframe loaded — if a cloud doc is pending, fetch + post its bytes. */
    async handleFrameLoad() {
        if (!this._pendingCloudDocId) return;
        const docId = this._pendingCloudDocId;
        try {
            const base64 = await this._fetchCloudBase64(docId);
            // Modal may have been closed / another doc opened while fetching.
            if (this._pendingCloudDocId !== docId || !this.showPreviewModal) return;
            if (!base64) throw new Error('Empty document');
            const iframe = this.template.querySelector('.sf-preview-frame');
            if (iframe && iframe.contentWindow) {
                iframe.contentWindow.postMessage(JSON.stringify({
                    type: 'loadPdfBase64',
                    data: base64
                }), '*');
            }
        } catch (e) {
            this.showPreviewModal = false;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not load preview',
                message: (e && e.body && e.body.message) || (e && e.message) || 'Cloud fetch failed',
                variant: 'error'
            }));
        }
    }

    /** Chunked cloud fetch: first chunk (returns size), then the rest in parallel. */
    async _fetchCloudBase64(documentId) {
        const CHUNK = 1200000; // multiple of 3 so base64 slices concatenate
        const first = await getCloudDocChunk({
            agreementId: this.recordId, rangeStart: 0, rangeLen: CHUNK, documentId
        });
        if (!first || !first.base64) return '';
        const size = Number(first.size) || 0;
        if (Math.floor(first.base64.length * 3 / 4) >= size) return first.base64;

        const jobs = [];
        for (let start = CHUNK; start < size; start += CHUNK) {
            jobs.push(getCloudDocChunk({
                agreementId: this.recordId, rangeStart: start, rangeLen: CHUNK, documentId
            }));
        }
        const rest = await Promise.all(jobs);
        return first.base64 + rest.map(r => (r && r.base64) || '').join('');
    }

    /** Save base64 bytes as a browser download (cloud docs with no share link). */
    _saveBase64AsFile(base64, fileName) {
        const bin = atob(base64);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        const blob = new Blob([bytes], { type: 'application/pdf' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = fileName.toLowerCase().endsWith('.pdf') ? fileName : fileName + '.pdf';
        a.click();
        setTimeout(() => URL.revokeObjectURL(a.href), 10000);
    }

    closePreview() {
        this.showPreviewModal = false;
        this.previewUrl = '';
        this.previewDownloadUrl = '';
        this._pendingCloudDocId = null;
    }

    handleDownloadFromPreview() {
        if (!this.previewDownloadUrl) return;
        window.open(this.previewDownloadUrl, '_blank');
    }
}
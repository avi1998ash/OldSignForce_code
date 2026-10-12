import { LightningElement, api, track, wire } from 'lwc';
import { getRecord, getRecordNotifyChange } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { stripNs, vfPageUrl } from 'c/nsUtils';
import { friendlyError } from 'c/signforceErrors';
import getEligibleTemplates from '@salesforce/apex/TemplateService.getEligibleTemplates';
// Materializes template-level signers/fields (stored as JSON on the template)
// into real Signer__c / Signature_Field__c rows on a freshly auto-created
// agreement. Best-effort: failures here must NOT lose the created agreement.
// The "Mapped" variant additionally applies a per-signer email override map
// (from STEP 2 — SIGNERS); passing '{}' makes it behave like the original
// 2-arg materializeSignersAndFields (no override), preserving live behavior.
// Signer-Mapping step support. getTemplateLayout returns the template's
// layout JSON (signers[] + fields[]); getRecordEmailFields returns the open
// record's Email-type field values so users can map each template signer to a
// real email; materializeSignersAndFieldsMapped is the override-aware
// materialize that applies the per-signer email mapping before inserting rows.
import getTemplateLayout from '@salesforce/apex/TemplateService.getTemplateLayout';
import getRecordEmailFields from '@salesforce/apex/TemplateService.getRecordEmailFields';
import materializeSignersAndFieldsMapped from '@salesforce/apex/TemplateService.materializeSignersAndFieldsMapped';
import prefillAgreementFields from '@salesforce/apex/DocumentGenerationService.prefillAgreementFields';
// Server-side helper that converts the template DOCX to PDF via Lambda
// and returns an S3 presigned URL. Used to preview DOCX templates inline
// (browsers can't render Word files directly in an iframe).
import getTemplatePreviewUrl from '@salesforce/apex/TemplateService.getTemplatePreviewUrl';
// Returns the ContentVersion Id of a Salesforce-stored PDF preview of the
// template (built once, cached). Lets us render the preview straight from
// Salesforce via /apex/PDFPreview?cvId=... — instant, no AWS round-trip.
import getStoredTemplatePreviewCvId from '@salesforce/apex/TemplateService.getStoredTemplatePreviewCvId';
// Server helper that converts a DOCX ContentVersion to PDF via Lambda and
// returns an S3 presigned URL. Used by "View File" button to preview the
// just-generated document inline without leaving the modal.
import getPreviewUrlForContentVersion from '@salesforce/apex/DocumentHistoryController.getPreviewUrlForContentVersion';
import generate from '@salesforce/apex/DocumentGenerationService.generate';
import tagAgreementSource from '@salesforce/apex/DocumentGenerationService.tagAgreementSource';
import listExistingDrafts from '@salesforce/apex/DocumentGenerationService.listExistingDrafts';
// Anchor resolution — bind template fields to merge tags so they track reflow.
import getMarkerMergedPreview from '@salesforce/apex/DocumentGenerationService.getMarkerMergedPreview';
import getAgreementFieldsForAnchor from '@salesforce/apex/DocumentGenerationService.getAgreementFieldsForAnchor';
import saveResolvedFieldPositions from '@salesforce/apex/DocumentGenerationService.saveResolvedFieldPositions';
import saveAnchorDiag from '@salesforce/apex/DocumentGenerationService.saveAnchorDiag';
import getPublicPreviewUrl from '@salesforce/apex/DocumentEditorController.getPublicPreviewUrl';
import createAgreement from '@salesforce/apex/AgreementController.createAgreement';
import uploadTier1Document from '@salesforce/apex/AgreementController.uploadTier1Document';
import storeOriginalChunk from '@salesforce/apex/SalesforceChunkUpload.storeOriginalChunk';
import isOriginalReady from '@salesforce/apex/SalesforceChunkUpload.isOriginalReady';
// S3 storage flow — same Apex methods used by createAgreement LWC.
// DOC/DOCX always go to S3 via Lambda (regardless of size); PDFs route by size.
import getStorageTierForUpload from '@salesforce/apex/AgreementController.getStorageTierForUpload';
import createAgreementDocumentS3 from '@salesforce/apex/AgreementController.createAgreementDocumentS3';


/**
 * X of a character sitting `within` characters into a pdf.js text run.
 *
 * pdf.js reports ONE origin per run. A merged value joins with the text around it
 * into a single run, so taking the run's origin would place an anchored field left
 * by the width of everything preceding it on that line — an error small enough to
 * pass the horizontal sanity guard unnoticed.
 *
 * Must stay identical to templateFieldEditor's copy: the design offset and the
 * resolved position have to be measured from the same point.
 */
function xWithinRun(item, within) {
    const len = String((item && item.str) || '').length;
    if (!len || !within) return (item && item.x) || 0;
    return (item.x || 0) + (item.w || 0) * (within / len);
}

/**
 * generateDocument — quick-action LWC for record pages.
 *
 * M5-2 — Deferred agreement choice + redesigned UI:
 *
 *   Flow when Auto_Create_Agreement is ON:
 *     1. User clicks Generate → server renders the document (returns base64).
 *     2. We check for existing Draft agreements for this record + template.
 *     3a. If 0 drafts exist → create new agreement immediately, attach file,
 *         show success card with "Open agreement".
 *     3b. If ≥1 drafts exist → show drafts table with "Use this" + "Create
 *         new" buttons. User picks → we attach the file to their choice.
 *
 *   Flow when Auto_Create_Agreement is OFF:
 *     - Server saves file to source record's Files (existing behavior).
 *     - Show success card. Optional navigation to file preview after delay.
 *
 *   Pending file state:
 *     When the existing-drafts panel is shown, the generated bytes (base64)
 *     are kept on `_pendingFile` until the user picks a target. We don't
 *     write anything to Salesforce until they decide — that way "Cancel"
 *     truly cancels (no orphan agreements, no orphan files).
 */
export default class GenerateDocument extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;

    // ── State buckets ────────────────────────────────────────────────
    @track templates = [];
    @track selectedTemplateId = null;
    @track isLoading = true;
    @track isGenerating = false;
    @track result = null;

    // Preview
    @track previewOpen = false;
    @track previewLoading = false;
    @track previewError = null;
    @track previewRows = [];

    // ─── Template File Preview Modal ───────────────────────────────
    // Shown when user clicks "Preview Template" near the format pills.
    // Lets users see what the raw template DOCX/PDF looks like before
    // they generate. Uses the same /apex/PDFPreview?cvId=... route that
    // documentGenerationHistory uses, which is LWS-safe (relative URL).
    @track showTemplatePreview = false;
    @track templatePreviewLoading = false;
    @track templatePreviewUrl = '';
    @track templatePreviewName = '';

    // ─── Signer-Mapping step (STEP 2 — SIGNERS) ───────────────────
    // ADDITIVE: only ever shown for auto-create templates that carry
    // template-level signers OR any UNASSIGNED fields. Templates with
    // NO signers AND NO unassigned fields leave hasTemplateSigners=false
    // and generate exactly as before.
    //   signerMapping rows are a concat of two kinds:
    //     signer row: { kind:'signer', key, name, role, order, email, useManual }
    //     field row:  { kind:'field', idx, label, email, useManual }
    //       where idx is the 0-based index into layout.fields[] of an
    //       UNASSIGNED field (signerKey blank or not matching any signer).
    //   recordEmailOptions:  combobox options built from the open record's
    //                        Email-type fields, always ending with a
    //                        "Type manually…" sentinel option.
    @track signerMapping = [];
    @track recordEmailOptions = [];
    @track hasTemplateSigners = false;
    // Sentinel combobox value meaning "switch this row to manual entry".
    MANUAL_OPTION_VALUE = '__manual__';

    // Existing-drafts confirmation panel
    @track existingDrafts = [];
    @track isProcessingChoice = false;
    _pendingFile = null;   // { filename, base64, byteSize, outputFormat } - kept until user chooses

    // Storage config — populated by getStorageTierForUpload wire.
    // Same shape as createAgreement LWC: tier, lambdaEndpoint, tier1MaxBytes,
    // chunkThresholdBytes, maxUploadBytes, orgId.
    _config = null;

    // Final agreement state
    @track agreementId = null;
    // Preview source for the agreement-success card "View File" button.
    // S3 paths (DOCX / large PDF) set agreementPreviewUrl; small PDF (Tier1)
    // keeps the bytes for an in-memory blob preview.
    @track agreementPreviewUrl = null;
    _agreementPdfBase64 = null;
    _agreementPdfName = null;
    @track agreementName = null;
    @track agreementErrorMessage = null;
    @track agreementWasReused = false;   // true if user picked an existing draft
    // Set only while anchored fields are being resolved; drives the off-screen
    // anchor-extraction iframe in the template.
    @track anchorFrameUrl = null;

    /* ── Wires ───────────────────────────────────────────────────── */

    // Storage config wire — loads S3 endpoint + tier thresholds from CMT.
    // Mirrors the pattern used in createAgreement LWC. Without a configured
    // Lambda endpoint, S3 upload paths will throw a clear error.
    @wire(getStorageTierForUpload)
    wiredStorageConfig({ data, error }) {
        if (data) {
            this._config = data;
            console.log('[SignForce generateDocument] Storage config loaded:', JSON.stringify(data));
        } else if (error) {
            console.error('[SignForce generateDocument] Failed to load storage config, using fallbacks', error);
            this._config = {
                tier: 'Tier1',
                lambdaEndpoint: '',
                tier1MaxBytes: 3145728,
                chunkThresholdBytes: 7340032,
                maxUploadBytes: 20971520,
                orgId: ''
            };
        }
    }

    // Hold onto the wire results so we can refreshApex() them on demand.
    // This is the fix for the "stale templates / stale record" bug:
    // getEligibleTemplates is @AuraEnabled(cacheable=true) and getRecord uses
    // Lightning Data Service cache, so without manual refresh the UI keeps
    // showing the values from the first load until the page is reloaded.
    _wiredTemplatesResult;
    _wiredRecordResult;
    _hasMountedOnce = false;

    /**
     * Quick Action ("ScreenAction") reuse fix.
     *
     * Salesforce's Quick Action framework does NOT destroy the LWC instance
     * between modal opens. When the user closes the action modal and edits
     * the record (or another tab edits it), then re-opens the same action,
     * the component is the SAME INSTANCE — same wire data, same LDS cache.
     * The result: the user sees the values from the FIRST open of the
     * action, even after editing the record, until they reload the page.
     *
     * connectedCallback fires every time the component is inserted into
     * the DOM, including each Quick Action open, so this is the right
     * place to invalidate the caches. Without this, the @wire decorator
     * alone won't re-fetch because the parameters (recordId, objectApiName)
     * haven't changed.
     *
     * NOTE: The very first mount happens BEFORE wires have completed, so
     * skip the refresh on first mount (the wires are about to fetch fresh
     * data anyway). On subsequent mounts (re-opens), force-refresh.
     */
    connectedCallback() {
        if (!this._hasMountedOnce) {
            this._hasMountedOnce = true;
            return;
        }
        // Re-open: tell LDS the record might have changed, then refresh wires.
        this._invalidateCaches('connectedCallback re-open');
    }

    /**
     * Re-usable cache invalidator. Called from connectedCallback (when the
     * Quick Action re-opens) and from handleGenerate (just before the
     * Apex call). Safe to call when wires haven't initialized yet — it
     * skips them.
     */
    async _invalidateCaches(reason) {
        try {
            if (this.recordId) {
                // Tell Lightning Data Service the record is dirty — this
                // forces any @wire(getRecord) anywhere in the page to
                // re-fetch from the server.
                getRecordNotifyChange([{ recordId: this.recordId }]);
            }
            const tasks = [];
            if (this._wiredTemplatesResult) tasks.push(refreshApex(this._wiredTemplatesResult));
            if (this._wiredRecordResult) tasks.push(refreshApex(this._wiredRecordResult));
            if (tasks.length) await Promise.all(tasks);
        } catch (e) {
            console.warn('[SignForce] cache invalidate (' + reason + ') failed (non-fatal):', e);
        }
    }

    @wire(getEligibleTemplates, { objectApiName: '$objectApiName' })
    wiredTemplates(result) {
        this._wiredTemplatesResult = result;
        const { data, error } = result;
        if (data) {
            this.templates = stripNs(data);
            this.isLoading = false;
        } else if (error) {
            console.error('getEligibleTemplates failed', error);
            this.isLoading = false;
            this.toast('Error', 'Could not load templates', 'error');
        }
    }

    @wire(getRecord, { recordId: '$recordId', layoutTypes: ['Full'] })
    wiredRecord(result) {
        this._wiredRecordResult = result;
        const { data, error } = result;
        if (data) {
            this._record = data;
            this.refreshPreview();
        } else if (error) {
            console.warn('getRecord failed (preview won\'t show values)', error);
        }
    }

    /* ── Computed ────────────────────────────────────────────────── */

    get showEmpty() { return !this.isLoading && this.templates.length === 0; }

    /**
     * The picker is shown when:
     *   - Templates loaded
     *   - We're not currently in the "drafts decision" state
     *   - We don't have a final result yet
     *   - We don't have a final agreement yet
     *   - We don't have a final error yet
     */
    get showMain() {
        if (this.isLoading || this.templates.length === 0) return false;
        if (this.showExistingDraftsPanel) return false;
        if (this.showFileResult) return false;
        if (this.showAgreementResult) return false;
        if (this.showAgreementError) return false;
        if (this.showGenerationError) return false;
        return true;
    }

    get templateOptions() {
        return this.templates.map(t => ({ label: t.Name, value: t.Id }));
    }

    get selectedTemplate() {
        return this.templates.find(t => t.Id === this.selectedTemplateId) || null;
    }

    get fieldsToMerge() {
        const t = this.selectedTemplate;
        if (!t || !t.Template_Fields__r) return [];
        return t.Template_Fields__r;
    }

    get previewToggleLabel() {
        return this.previewOpen ? 'Hide preview' : 'Show preview';
    }

    get generateButtonLabel() {
        const t = this.selectedTemplate;
        if (t && t.Auto_Create_Agreement__c) return 'Generate & Create Agreement';
        return 'Generate Document';
    }

    /* ── loader copy ──
     * The two templates end in different places, so the wait says which one is
     * coming. Promising an agreement and producing a saved file — or the other
     * way round — is a small lie that costs the reader a moment of confusion at
     * exactly the point they are already waiting. */

    get generateLoaderTitle() {
        const t = this.selectedTemplate;
        return t && t.Auto_Create_Agreement__c
            ? 'Building your agreement'
            : 'Building your document';
    }

    get generateLoaderMessage() {
        const t = this.selectedTemplate;
        return t && t.Auto_Create_Agreement__c
            ? 'Filling in the template, then opening it so you can add signers. This takes a few seconds.'
            : 'Reading the record and filling in the template. This takes a few seconds.';
    }

    /* ── Result-banner routing ──
     * Mutually exclusive states; the template uses these directly.
     */
    get showGenerationError() {
        return !!this.result && this.result.status !== 'Success'
            && !this.agreementId && !this.agreementErrorMessage
            && !this.showExistingDraftsPanel;
    }
    get showFileResult() {
        if (!this.result || this.result.status !== 'Success') return false;
        if (this.result.autoCreateAgreement) return false; // agreement variant takes over
        if (this.agreementId) return false;
        return true;
    }
    get showAgreementResult() { return !!this.agreementId; }
    get showAgreementError() { return !!this.agreementErrorMessage && !this.agreementId; }
    get showExistingDraftsPanel() {
        return this.existingDrafts && this.existingDrafts.length > 0
            && !this.agreementId && !this.agreementErrorMessage;
    }

    get isMultipleDrafts() { return this.existingDrafts.length > 1; }

    get agreementResultTitle() {
        return this.agreementWasReused
            ? 'Document attached to existing agreement'
            : 'Agreement created';
    }

    get agreementResultHint() {
        if (this.agreementWasReused) {
            return this.agreementName
                ? `The document was attached to "${this.agreementName}". Open it to add signers and place fields.`
                : 'The document was attached to the existing agreement.';
        }
        return this.agreementName
            ? `Saved as "${this.agreementName}". Open it to add signers and place signature fields.`
            : 'Open the agreement to add signers and place signature fields.';
    }

    /* ── Handlers ────────────────────────────────────────────────── */

    handleTemplateChange(e) {
        this.selectedTemplateId = e.detail.value;
        this.resetResultState();
        // Reset signer-mapping state on every template change. _loadSignerMapping
        // re-populates it only when the new template is auto-create AND carries
        // template-level signers — otherwise hasTemplateSigners stays false and
        // the no-signers path is completely unchanged.
        this._resetSignerMapping();
        this._loadSignerMapping();
    }

    /**
     * Build the Signer-Mapping (STEP 2) state for the currently selected
     * template. Best-effort: any failure leaves hasTemplateSigners=false so
     * generation falls back to the unchanged behavior. Runs only for
     * Auto_Create_Agreement__c templates; for everything else it no-ops.
     */
    async _loadSignerMapping() {
        const tpl = this.selectedTemplate;
        if (!tpl || tpl.Auto_Create_Agreement__c !== true) return;

        try {
            const layoutJson = await getTemplateLayout({ templateId: this.selectedTemplateId });
            if (!layoutJson) return;

            let layout;
            try {
                layout = JSON.parse(layoutJson);
            } catch (parseErr) {
                console.warn('[SignForce] template layout JSON parse failed (non-fatal):', parseErr);
                return;
            }

            const signers = (layout && Array.isArray(layout.signers)) ? layout.signers : [];
            const fields = (layout && Array.isArray(layout.fields)) ? layout.fields : [];
            // Guard: the selected template may have changed while awaiting.
            if (tpl.Id !== this.selectedTemplateId) return;

            // Set of defined signer keys — a field whose signerKey is blank
            // OR not in this set is UNASSIGNED and gets its own mapping row.
            const signerKeySet = new Set(
                signers
                    .map(s => (s && s.key !== undefined && s.key !== null) ? String(s.key) : '')
                    .filter(k => k !== '')
            );
            const unassignedFieldIdx = [];
            fields.forEach((f, idx) => {
                const sk = (f && f.signerKey !== undefined && f.signerKey !== null)
                    ? String(f.signerKey).trim()
                    : '';
                if (sk === '' || !signerKeySet.has(sk)) {
                    unassignedFieldIdx.push(idx);
                }
            });

            // Nothing to map → leave the no-signers path completely unchanged.
            if (signers.length === 0 && unassignedFieldIdx.length === 0) {
                this.hasTemplateSigners = false;
                this.signerMapping = [];
                return;
            }

            // Pull the open record's Email-type field values to offer as
            // auto-fill choices. Best-effort — if it fails we fall back to
            // manual entry only.
            let emailFields = [];
            try {
                emailFields = await getRecordEmailFields({ recordId: this.recordId });
            } catch (efErr) {
                console.warn('[SignForce] getRecordEmailFields failed (manual entry only):', efErr);
                emailFields = [];
            }
            if (tpl.Id !== this.selectedTemplateId) return;

            // Build combobox options: only fields with a non-blank value, with
            // a label "<field label> — <value>" and value = the email itself.
            // ALWAYS append the "Type manually…" sentinel.
            const recordEmails = [];
            const options = [];
            (emailFields || []).forEach(f => {
                if (!f) return;
                const value = (f.value || '').trim();
                if (!value) return;
                const label = (f.label || f.fieldLabel || 'Email') + ' - ' + value;
                options.push({ label, value });
                recordEmails.push(value);
            });
            options.push({ label: 'Type manually…', value: this.MANUAL_OPTION_VALUE });

            const firstRecordEmail = recordEmails.length > 0 ? recordEmails[0] : null;

            // Signer rows — DEFINED template signers (unchanged behavior, plus
            // an explicit kind:'signer' tag so the template/handlers can branch).
            const signerRows = signers.map(s => {
                const storedEmail = (s && s.email) ? String(s.email).trim() : '';
                // Preserve the email the admin set on the template signer. Only
                // fall back to a record email when the template left it blank
                // (a signer meant to be filled from the record at generation).
                const email = storedEmail || firstRecordEmail || '';
                // useManual when there are no record emails OR the chosen email
                // isn't among the record options (a fixed template email usually
                // isn't, so it shows pre-filled in the manual input).
                const useManual = recordEmails.length === 0
                    || !recordEmails.includes(email);
                return {
                    kind: 'signer',
                    key: s && s.key ? s.key : '',
                    name: s && s.name ? s.name : '',
                    role: s && s.role ? s.role : 'Signer',
                    order: (s && s.order !== undefined && s.order !== null) ? s.order : null,
                    email: email || '',
                    useManual
                };
            });

            // Field rows — one per UNASSIGNED field, keyed by its 0-based index
            // in layout.fields[]. Each is assigned to a DEFINED signer via a
            // dropdown, so it defaults to the first signer's email (which the
            // materialize resolves back to that signer). Falls back to the first
            // record email only when no signer has an email yet.
            const firstSignerEmail = (signerRows.find(s => s.email && s.email.trim()) || {}).email || '';
            const fieldRows = unassignedFieldIdx.map(idx => {
                const f = fields[idx] || {};
                const type = (f.type ? String(f.type) : 'Field');
                const page = (f.page !== undefined && f.page !== null) ? f.page : 1;
                const email = firstSignerEmail || firstRecordEmail || '';
                const useManual = recordEmails.length === 0
                    || !recordEmails.includes(email);
                return {
                    kind: 'field',
                    idx,
                    label: type + ' (page ' + page + ')',
                    email: email || '',
                    useManual
                };
            });

            this.recordEmailOptions = options;
            this.signerMapping = signerRows.concat(fieldRows);
            // Show the step when there are signer rows OR field rows.
            this.hasTemplateSigners = (signerRows.length > 0 || fieldRows.length > 0);
        } catch (err) {
            console.warn('[SignForce] _loadSignerMapping failed (non-fatal):', err);
            this._resetSignerMapping();
        }
    }

    /** Clear all Signer-Mapping (STEP 2) state. */
    _resetSignerMapping() {
        this.hasTemplateSigners = false;
        this.signerMapping = [];
        this.recordEmailOptions = [];
    }

    /* ── STEP-2 row split (for the template) ─────────────────────── */

    /** DEFINED template-signer rows only. */
    get signerRows() {
        return (this.signerMapping || [])
            .filter(r => r && r.kind === 'signer')
            .map(r => {
                const hasOrder = r.order !== null && r.order !== undefined && r.order !== '';
                const nameTrim = (r.name && String(r.name).trim()) || '';
                // Fall back to "Signer N" when the template row has no name,
                // so the mapping row is never blank/anonymous.
                const displayName = nameTrim || (hasOrder ? ('Signer ' + r.order) : 'Signer');
                return {
                    ...r,
                    displayName,
                    orderLabel: hasOrder ? ('Order ' + r.order) : ''
                };
            });
    }

    /** UNASSIGNED-field rows only. */
    get fieldRows() {
        return (this.signerMapping || []).filter(r => r && r.kind === 'field');
    }

    /** Options for the "assign to signer" dropdown on each unassigned field —
     *  the defined signers that already have an email, labelled by name + order.
     *  The value is the signer's email, which the Apex materialize resolves back
     *  to that same existing signer, so several fields can share one signer
     *  without creating a duplicate recipient. */
    get signerPickerOptions() {
        return this.signerRows
            .filter(s => s.email && String(s.email).trim())
            .map(s => ({
                label: s.displayName + (s.orderLabel ? ' · ' + s.orderLabel : ''),
                value: String(s.email).trim()
            }));
    }

    get hasSignerPickerOptions() {
        return this.signerPickerOptions.length > 0;
    }

    /** True when the open record actually exposes Email-type field values to
     *  pick from — otherwise the "Select an email…" dropdown is pointless and
     *  is hidden, leaving just the clean manual email field. */
    get hasRecordEmails() {
        return (this.recordEmailOptions || []).some(o => o && o.value !== this.MANUAL_OPTION_VALUE);
    }

    /** True when there is at least one UNASSIGNED-field row to map. */
    get hasUnassignedFields() {
        return this.fieldRows.length > 0;
    }

    /**
     * Resolve which mapping row a control belongs to from its dataset.
     * Signer rows carry data-key; UNASSIGNED-field rows carry data-idx.
     * Returns a predicate that matches the target row.
     */
    _rowMatcher(target) {
        const ds = (target && target.dataset) || {};
        if (ds.key !== undefined && ds.key !== null && ds.key !== '') {
            const key = ds.key;
            return row => row.kind === 'signer' && row.key === key;
        }
        // Field rows: data-idx is the 0-based layout.fields[] index (a string).
        const idx = ds.idx;
        return row => row.kind === 'field' && String(row.idx) === String(idx);
    }

    /**
     * Combobox change on a mapping row (signer OR unassigned field). Picking
     * "Type manually…" flips the row into manual mode (revealing the email
     * input); picking any record email sets the row's email and clears manual
     * mode. Immutable map update — matches by data-key (signer) or data-idx
     * (field) so @track re-renders the right row.
     */
    handleMappingEmailChange(e) {
        const matches = this._rowMatcher(e.target);
        const value = e.detail.value;
        this.signerMapping = this.signerMapping.map(row => {
            if (!matches(row)) return row;
            if (value === this.MANUAL_OPTION_VALUE) {
                return { ...row, useManual: true };
            }
            return { ...row, email: value, useManual: false };
        });
    }

    /**
     * Manual email input change on a mapping row (signer OR unassigned field).
     * Stores the typed value and keeps the row in manual mode. Immutable map
     * update — matches by data-key (signer) or data-idx (field).
     */
    handleMappingManualChange(e) {
        const matches = this._rowMatcher(e.target);
        const value = e.detail ? e.detail.value : e.target.value;
        this.signerMapping = this.signerMapping.map(row =>
            matches(row) ? { ...row, email: value, useManual: true } : row
        );
    }

    /**
     * Build the mapping object passed to materializeSignersAndFieldsMapped.
     * New shape (replaces the old flat per-signer map):
     *   {
     *     signers:     { [signerKey]: { name, email } },  // DEFINED signers
     *     fieldEmails: { [fieldIndex]: email }            // UNASSIGNED fields
     *   }
     * Apex applies signer emails when materializing template signers, and
     * creates/reuses a signer per unassigned field from its mapped email.
     */
    _buildSignerMapping() {
        const signers = {};
        const fieldEmails = {};
        (this.signerMapping || []).forEach(row => {
            if (!row) return;
            if (row.kind === 'field') {
                if (row.idx === undefined || row.idx === null) return;
                fieldEmails[String(row.idx)] = row.email;
                return;
            }
            // signer row
            if (!row.key) return;
            signers[row.key] = { name: row.name, email: row.email };
        });
        return { signers, fieldEmails };
    }

    /**
     * Validate every mapped row (signer AND unassigned field) has a
     * syntactically valid email before an auto-create generation. Returns true
     * when all rows are valid; otherwise toasts and returns false to block.
     */
    _validateSignerMapping() {
        const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        const invalid = (this.signerMapping || []).filter(row => {
            const email = (row && row.email ? String(row.email) : '').trim();
            return !emailRe.test(email);
        });
        if (invalid.length > 0) {
            const who = invalid
                .map(r => {
                    if (r.kind === 'field') return r.label || 'an unassigned field';
                    return r.name || r.role || 'a signer';
                })
                .join(', ');
            this.toast(
                'Email required',
                'Enter a valid email for: ' + who + '.',
                'error'
            );
            return false;
        }

        // Duplicate check applies only to DEFINED signers — two signer slots
        // with the same email are ambiguous. Unassigned FIELD rows are exempt:
        // several fields legitimately point at the same signer, and Apex
        // collapses a shared email onto that one existing recipient.
        const seenEmails = new Set();
        for (const row of this.signerMapping || []) {
            if (!row || row.kind === 'field') continue;
            const emailTrim = (row.email ? String(row.email) : '').trim().toLowerCase();
            if (!emailTrim) continue;
            if (seenEmails.has(emailTrim)) {
                this.toast(
                    'Duplicate email address',
                    `The email "${row.email}" is assigned to more than one signer. Give each signer a unique email.`,
                    'error'
                );
                return false;
            }
            seenEmails.add(emailTrim);
        }

        return true;
    }

    /* ── Anchor resolution (zero-drift) ──────────────────────────────────────
       After an agreement is created from a template, re-place any fields that
       were anchored to a merge tag: find where that tag's VALUE landed on the
       merged document and set the field to valuePos + storedOffset. Fields with
       no anchor (or no confident match) keep their absolute position, so this
       is strictly additive and never makes placement worse. */
    async resolveAnchoredFields(agreementId, templateId, recordId) {
        // Every step below can legitimately find nothing to do, so each one records
        // why it stopped. Without this a field that failed to move is
        // indistinguishable from one that had no anchor, and the only way to tell
        // was to generate again and guess.
        const diag = { stage: 'start', agreementId, templateId, recordId, fields: [] };
        const report = async () => {
            try { await saveAnchorDiag({ diagJson: JSON.stringify(diag) }); } catch (e) { /* never break generation */ }
        };

        if (!agreementId || !templateId || !recordId) { diag.stage = 'missing-ids'; return report(); }

        const layoutJson = await getTemplateLayout({ templateId });
        if (!layoutJson) { diag.stage = 'no-layout'; return report(); }
        let layout;
        try { layout = JSON.parse(layoutJson); } catch (e) { diag.stage = 'bad-layout-json'; return report(); }
        const layoutFields = (layout && Array.isArray(layout.fields)) ? layout.fields : [];
        const anchored = layoutFields.filter((f) => f && f.anchorTag);
        diag.layoutFields = layoutFields.length;
        diag.anchored = anchored.length;
        if (!anchored.length) { diag.stage = 'no-anchored-fields'; return report(); }

        const [createdFields, markerRes] = await Promise.all([
            getAgreementFieldsForAnchor({ agreementId }),
            getMarkerMergedPreview({ templateId, recordId })
        ]);
        const mergedCvId = markerRes && markerRes.cvId;
        const markers = (markerRes && markerRes.markers) || {};   // token -> tagPath
        diag.createdFields = (createdFields || []).length;
        diag.markerCvId = mergedCvId || null;
        diag.markers = markers;
        if (!mergedCvId) { diag.stage = 'no-marker-preview'; return report(); }
        if (!createdFields || !createdFields.length) { diag.stage = 'no-created-fields'; return report(); }
        // Invert to tagPath -> token for lookup.
        const tagToToken = {};
        Object.keys(markers).forEach((tok) => { tagToToken[markers[tok]] = tok; });

        const previewUrl = await getPublicPreviewUrl({ contentVersionId: mergedCvId });
        diag.previewUrl = previewUrl ? String(previewUrl).slice(0, 120) : null;
        if (!previewUrl) { diag.stage = 'no-preview-url'; return report(); }

        const items = await this._extractTextItems(previewUrl);
        diag.itemCount = (items || []).length;
        if (!items || !items.length) { diag.stage = 'no-text-items'; return report(); }

        const updates = [];
        anchored.forEach((lf) => {
            const row = { tag: lf.anchorTag, occ: lf.anchorOcc, designX: lf.x, designY: lf.y, page: lf.page };
            const created = this._matchCreatedField(createdFields, lf);
            if (!created) { row.stop = 'no-created-match'; diag.fields.push(row); return; }
            // An anchor on a different page than the field describes content the
            // field does not sit beside, and following it would carry the field off
            // its own page. templateFieldEditor no longer creates these; this
            // catches layouts saved before that rule existed.
            if (lf.anchorPage != null && Number(lf.anchorPage) !== (Number(lf.page) || 1)) {
                row.stop = 'cross-page-anchor'; row.anchorPage = lf.anchorPage;
                diag.fields.push(row); return;
            }
            const tagKey = String(lf.anchorTag).split(':')[0].trim();
            const token = tagToToken[tagKey];
            if (!token) { row.stop = 'no-token-for-tag'; diag.fields.push(row); return; }
            // A marker is always on the value's first line, so it survives long
            // or wrapping values that broke plain value-matching.
            const pos = this._findValuePosition(items, token, Number(lf.anchorOcc) || 0);
            if (!pos) { row.stop = 'token-not-found'; row.token = token; diag.fields.push(row); return; }
            // Guard against a wrong value match: the tag's column (X) shouldn't
            // jump far between the template and the merged doc — reflow is mostly
            // vertical. A large horizontal jump means we matched the wrong text,
            // so keep the absolute position instead.
            const tagDesignX = (Number(lf.x) || 0) - (Number(lf.anchorDx) || 0);
            row.token = token;
            row.foundX = pos.x; row.foundY = pos.y; row.foundPage = pos.page;
            row.tagDesignX = tagDesignX;
            if (Math.abs(pos.x - tagDesignX) > 200) { row.stop = 'x-jump-guard'; diag.fields.push(row); return; }
            const newX = pos.x + (Number(lf.anchorDx) || 0);
            const newY = pos.y + (Number(lf.anchorDy) || 0);
            row.stop = 'updated'; row.newX = newX; row.newY = newY;
            diag.fields.push(row);
            updates.push({ id: created.id, x: newX, y: newY, page: pos.page });
        });

        diag.updates = updates.length;
        diag.stage = updates.length ? 'saved' : 'nothing-to-update';
        if (updates.length) {
            await saveResolvedFieldPositions({ positionsJson: JSON.stringify(updates) });
        }
        return report();
    }

    /** Render the merged PDF off-screen and resolve with pdf.js text-item
        positions.

        The frame MUST be the declarative <iframe> in this component's template.
        An iframe built with document.createElement and appended to document.body
        is sandboxed by Lightning Web Security: it never loads and never posts
        back, so extraction returned [] and every anchored field silently kept its
        drifted absolute position. templateFieldEditor uses the same declarative
        pattern, which is why capture worked while resolve did not. */
    _extractTextItems(previewUrl) {
        return new Promise((resolve) => {
            const url = previewUrl + (previewUrl.indexOf('?') === -1 ? '?' : '&') + 'sfAnchor=1';
            let done = false;
            const finish = (items) => {
                if (done) return; done = true;
                try { window.removeEventListener('message', onMsg); } catch (e) {}
                this.anchorFrameUrl = null;   // unmount the frame
                resolve(items);
            };
            const onMsg = (e) => {
                let data = e.data;
                if (typeof data === 'string') { try { data = JSON.parse(data); } catch (err) { return; } }
                if (data && data.type === 'textItems') finish(data.items || []);
            };
            window.addEventListener('message', onMsg);
            this.anchorFrameUrl = url;   // renders the declarative off-screen iframe
            setTimeout(() => finish([]), 25000);   // never hang the flow
        });
    }

    /** Find the created Signature_Field__c whose x/y/page/type match a layout
        field (materialize copies these verbatim). Near-exact only. */
    _matchCreatedField(createdFields, lf) {
        const lx = Number(lf.x) || 0, ly = Number(lf.y) || 0, lp = Number(lf.page) || 1;
        let best = null, bestD = Infinity;
        (createdFields || []).forEach((cf) => {
            if (String(cf.type) !== String(lf.type)) return;
            if ((Number(cf.page) || 1) !== lp) return;
            const d = Math.hypot((Number(cf.x) || 0) - lx, (Number(cf.y) || 0) - ly);
            if (d < bestD) { bestD = d; best = cf; }
        });
        return (best && bestD < 3) ? best : null;
    }

    /** Reading-order position of the Nth occurrence of a value string in the
        reassembled page text (762-ref, top-left origin). */
    _findValuePosition(items, value, occurrence) {
        const target = String(value).trim();
        if (!target) return null;
        const lines = {};
        (items || []).forEach((it) => {
            if (!it || !it.str) return;
            const key = it.page + ':' + Math.round((it.y || 0) / 3);
            (lines[key] = lines[key] || []).push(it);
        });
        const matches = [];
        Object.keys(lines).forEach((k) => {
            const li = lines[k].slice().sort((a, b) => (a.x || 0) - (b.x || 0));
            let combined = ''; const charItem = []; const charOff = [];
            li.forEach((it, idx) => {
                let n = 0;
                for (const ch of String(it.str)) { combined += ch; charItem.push(idx); charOff.push(n++); }
            });
            let from = 0, pos;
            while ((pos = combined.indexOf(target, from)) !== -1) {
                const it = li[charItem[pos]];
                // Offset INTO the run, not the run's origin: a merged value joins
                // with its surrounding text into one run, so taking the run origin
                // would place the field left by the width of the text before it.
                // templateFieldEditor measures the design anchor the same way.
                if (it) matches.push({ x: xWithinRun(it, charOff[pos]), y: it.y, page: it.page });
                from = pos + Math.max(1, target.length);
            }
        });
        matches.sort((a, b) => a.page - b.page || a.y - b.y || a.x - b.x);
        return matches[occurrence] || matches[0] || null;
    }

    async togglePreview() {
        this.previewOpen = !this.previewOpen;
        if (this.previewOpen) {
            // Refresh record before showing preview so the values the user
            // sees are guaranteed to match what'll be merged on generate.
            // Without this, preview can show first-loaded (stale) values
            // even after the record was edited.
            this.previewLoading = true;
            await this._invalidateCaches('preview-open');
            this.refreshPreview();
        }
    }

    /**
     * Open the template file in a modal preview iframe.
     *
     * Two paths based on template's output/file format:
     *   PDF templates → /apex/PDFPreview?cvId=<id> directly (browser renders PDFs natively)
     *   DOCX templates → call Apex getTemplatePreviewUrl which converts the
     *     DOCX to PDF via Lambda + returns an S3 presigned URL. Wrap the
     *     S3 URL through PDFPreview so the iframe shows a clean viewer.
     *
     * Why the DOCX detour: browsers can't render Word files in iframes.
     * We have to convert to PDF first. Lambda's convertToPdf action
     * (same one createAgreement uses for Word uploads) handles this.
     */
    async handlePreviewTemplate() {
        const tpl = this.selectedTemplate;
        if (!tpl || !tpl.Template_File_Id__c) {
            this.toast(
                'Cannot preview',
                'This template has no underlying file. Re-upload it from the Dynamic Document tab.',
                'error'
            );
            return;
        }

        // Detect format. Output_Format__c tells us what generated docs
        // will be; for the template file itself we infer from the uploaded
        // file (always DOCX from templateLibrary, but the format pill on
        // the LWC may say 'PDF' when the template's output format is PDF.
        // The underlying file is still DOCX in that case — Lambda renders
        // DOCX → PDF on generate. So we always need DOCX-style preview
        // unless the original upload was a PDF, which our current
        // templateLibrary doesn't support but might in the future).
        const fileName = (tpl.Template_File_Name__c || '').toLowerCase();
        const isPdfFile = fileName.endsWith('.pdf');

        this.templatePreviewName = tpl.Name || 'Template';
        this.templatePreviewLoading = true;
        this.templatePreviewUrl = '';
        this.showTemplatePreview = true;

        if (isPdfFile) {
            // PDF template — render directly through PDFPreview.page
            this.templatePreviewUrl = vfPageUrl('PDFPreview') + '?cvId='
                + encodeURIComponent(tpl.Template_File_Id__c)
                + '&ts=' + Date.now();
            setTimeout(() => { this.templatePreviewLoading = false; }, 4000);
            return;
        }

        // DOCX template — prefer a Salesforce-stored PDF preview (built once,
        // cached). Renders instantly from Salesforce with no AWS round-trip.
        try {
            const storedCvId = await getStoredTemplatePreviewCvId({ templateId: tpl.Id });
            if (storedCvId) {
                this.templatePreviewUrl = vfPageUrl('PDFPreview') + '?cvId='
                    + encodeURIComponent(storedCvId)
                    + '&ts=' + Date.now();
                setTimeout(() => { this.templatePreviewLoading = false; }, 4000);
                return;
            }
        } catch (e) {
            // No cached preview / lookup failed — fall back to on-demand conversion.
        }

        // Not cached yet — convert via Lambda this once (the lookup above also
        // kicked off a background build, so the next preview will be instant).
        try {
            const pdfUrl = await getTemplatePreviewUrl({ templateId: tpl.Id });
            if (!pdfUrl) {
                throw new Error('No URL returned from server');
            }
            if (pdfUrl.startsWith('base64:')) {
                // Render bytes via PDFPreview receive mode (LWS blocks blob: src).
                this._tplPreviewBase64 = pdfUrl.substring(7);
                this.templatePreviewUrl = vfPageUrl('PDFPreview') + '?mode=receive&ts=' + Date.now();
            } else {
                this._tplPreviewBase64 = null;
                this.templatePreviewUrl = vfPageUrl('PDFPreview') + '?pdfUrl='
                    + encodeURIComponent(pdfUrl)
                    + '&ts=' + Date.now();
            }
        } catch (err) {
            this.templatePreviewLoading = false;
            this.showTemplatePreview = false;
            const msg = err?.body?.message || err?.message || 'Could not load preview';
            this.toast('Preview failed', msg, 'error');
            return;
        }
        // Safety fallback in case onload never fires.
        setTimeout(() => { this.templatePreviewLoading = false; }, 4000);
    }

    _tplPreviewBase64 = null;

    /** Iframe finished loading — hide the spinner and hand over the PDF bytes. */
    handleTemplatePreviewLoaded(event) {
        this.templatePreviewLoading = false;
        if (this._tplPreviewBase64 && event?.target?.contentWindow) {
            try {
                event.target.contentWindow.postMessage(JSON.stringify({
                    type: 'loadPdfBase64',
                    data: this._tplPreviewBase64
                }), '*');
            } catch (e) { /* ignore */ }
        }
    }

    /** Close the template preview modal. */
    closeTemplatePreview() {
        this.showTemplatePreview = false;
        this.templatePreviewUrl = '';
        this.templatePreviewName = '';
        this.templatePreviewLoading = false;
    }

    /**
     * View the just-generated file in the same preview modal infrastructure
     * used for "Preview Template". Triggered from the success state's
     * "View File" button after a non-auto-create generation.
     *
     * Two paths based on output format:
     *   PDF  → render directly via /apex/PDFPreview?cvId=...
     *   DOCX → DOCX needs Lambda conversion first (PDFPreview.page only renders
     *          PDFs). Apex getPreviewUrlForContentVersion does the conversion
     *          and returns an S3 URL we wrap through PDFPreview's pdfUrl param.
     *
     * Reuses templatePreviewUrl / templatePreviewName / showTemplatePreview
     * state — they're generic to "show some PDF in our modal" and avoid
     * duplicating the modal markup in HTML.
     */
    async handleViewFile() {
        if (!this.result || !this.result.contentVersionId) {
            this.toast('Cannot preview', 'Generated file id not available.', 'error');
            return;
        }

        this.templatePreviewName = this.result.filename || 'Generated document';
        this.templatePreviewLoading = true;
        this.templatePreviewUrl = '';
        this.showTemplatePreview = true;

        // Detect output format. GenerationService sets result.outputFormat
        // ('PDF' / 'DOCX'). Fall back to filename suffix as a safety net.
        const fmt = (this.result.outputFormat || '').toUpperCase();
        const fname = (this.result.filename || '').toLowerCase();
        const isPdf = fmt === 'PDF' || (!fmt && fname.endsWith('.pdf'));

        if (isPdf) {
            // Fastest path: the freshly-generated PDF bytes are still in memory,
            // so show them straight from a blob URL — no server round-trip, no
            // Visualforce page, no conversion. This is the instant preview.
            if (this.result.outputBase64) {
                try {
                    this.templatePreviewUrl = this.pdfBase64ToBlobUrl(this.result.outputBase64);
                    setTimeout(() => { this.templatePreviewLoading = false; }, 300);
                    return;
                } catch (e) {
                    // fall through to the stored-file preview below
                }
            }
            // Fallback — render the already-stored ContentVersion via PDFPreview.
            this.templatePreviewUrl = vfPageUrl('PDFPreview') + '?cvId='
                + encodeURIComponent(this.result.contentVersionId)
                + '&ts=' + Date.now();
            setTimeout(() => { this.templatePreviewLoading = false; }, 4000);
            return;
        }

        // DOCX — convert via Lambda first
        try {
            const pdfUrl = await getPreviewUrlForContentVersion({
                contentVersionId: this.result.contentVersionId
            });
            if (!pdfUrl) throw new Error('No URL returned from server');
            this.templatePreviewUrl = vfPageUrl('PDFPreview') + '?pdfUrl='
                + encodeURIComponent(pdfUrl)
                + '&ts=' + Date.now();
        } catch (err) {
            this.templatePreviewLoading = false;
            this.showTemplatePreview = false;
            const msg = err?.body?.message || err?.message || 'Could not load preview';
            this.toast('Preview failed', msg, 'error');
            return;
        }
        setTimeout(() => { this.templatePreviewLoading = false; }, 4000);
    }

    /** Stop click propagation on modal body so clicking inside doesn't close it. */
    stopPropagation(e) { e.stopPropagation(); }

    /** True when the agreement's generated file can be previewed inline. */
    get canPreviewAgreement() {
        return !!this.agreementPreviewUrl || !!this._agreementPdfBase64;
    }

    /**
     * Preview the agreement's generated document in the same modal used by
     * the document-success card. Uses the captured S3 preview URL when present
     * (DOCX / large PDF); otherwise builds an in-memory blob from the small
     * PDF bytes (Tier1).
     */
    handleViewAgreementFile() {
        this.templatePreviewName = (this.result && this.result.filename)
            || this._agreementPdfName || 'Generated document';
        this.templatePreviewLoading = true;
        this.templatePreviewUrl = '';
        this.showTemplatePreview = true;

        if (this.agreementPreviewUrl) {
            this.templatePreviewUrl = this.agreementPreviewUrl;
        } else if (this._agreementPdfBase64) {
            try {
                this.templatePreviewUrl = this.pdfBase64ToBlobUrl(this._agreementPdfBase64);
            } catch (e) {
                this.templatePreviewLoading = false;
                this.showTemplatePreview = false;
                this.toast('Preview failed', 'Could not build a preview from the file.', 'error');
                return;
            }
        } else {
            this.templatePreviewLoading = false;
            this.showTemplatePreview = false;
            this.toast('Cannot preview', 'Preview is not available for this file.', 'error');
            return;
        }
        setTimeout(() => { this.templatePreviewLoading = false; }, 4000);
    }

    /** Convert base64 PDF bytes to a blob: URL for inline iframe preview. */
    pdfBase64ToBlobUrl(base64) {
        const bin = atob(base64);
        const len = bin.length;
        const bytes = new Uint8Array(len);
        for (let i = 0; i < len; i++) bytes[i] = bin.charCodeAt(i);
        return URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }));
    }

    handleCancel() {
        this.selectedTemplateId = null;
        this.previewOpen = false;
        this.previewRows = [];
        this.resetResultState();
        this._resetSignerMapping();
    }

    /**
     * Reset everything that drives the result UI. Used both when starting
     * fresh and when the user dismisses an existing-drafts panel.
     */
    resetResultState() {
        this.result = null;
        this.agreementId = null;
        this.agreementName = null;
        this.agreementErrorMessage = null;
        this.agreementWasReused = false;
        this.existingDrafts = [];
        this._pendingFile = null;
        this.agreementPreviewUrl = null;
        this._agreementPdfBase64 = null;
        this._agreementPdfName = null;
    }

    /* ── Main generation flow ───────────────────────────────────── */

    async handleGenerate() {
        if (!this.selectedTemplateId) return;

        // ── Cache busting (belt-and-braces) ──────────────────────────
        // connectedCallback already refreshes on Quick Action re-open,
        // but we ALSO refresh right before generate to catch the case
        // where the user edits the record in another tab while the
        // action modal is sitting open. Cheap & idempotent.
        await this._invalidateCaches('pre-generate');

        // Re-read tpl AFTER the refresh so we have the latest field list.
        const tpl = this.selectedTemplate;

        // Edge case — if a refresh revealed the template has been deleted
        // or deactivated by someone else, tell the user instead of letting
        // the Apex call fail with a less-clear "Template not found" error.
        if (!tpl) {
            this.toast(
                'Template not available',
                'This template was removed or deactivated. Pick another one.',
                'error'
            );
            this.selectedTemplateId = null;
            return;
        }

        const isAutoCreate = tpl && tpl.Auto_Create_Agreement__c === true;

        // STEP 2 — SIGNERS gate. For an auto-create template that carries
        // template-level signers, every mapped signer must have a valid email
        // before we generate. Templates without template-signers skip this
        // entirely (hasTemplateSigners is false) and behave exactly as before.
        if (isAutoCreate && this.hasTemplateSigners && !this._validateSignerMapping()) {
            return;
        }

        this.isGenerating = true;
        this.resetResultState();

        // Step 1 — render
        let genResult;
        try {
            genResult = await generate({
                templateId: this.selectedTemplateId,
                recordId: this.recordId
            });
            this.result = genResult;
        } catch (err) {
            // What Apex hands back is written for a developer — a template
            // syntax failure arrives as a docxtemplater stack trace, node_modules
            // paths and all. Translate it; keep the raw text as expandable detail.
            const fe = friendlyError(err);
            // No toast here. this.result renders the failure card with this exact
            // title and text, plus the technical detail behind a disclosure — a
            // toast carrying the same two lines just covers the card that explains
            // the problem properly.
            this.result = {
                status: 'Failure',
                errorTitle: fe.title,
                errorMessage: fe.text,
                errorDetail: fe.detail
            };
            this.isGenerating = false;
            return;
        }

        if (genResult.status !== 'Success') {
            const fe = friendlyError(genResult.errorMessage || 'Unknown error');
            // Same as above: the failure card below carries this message already.
            this.result = {
                ...genResult,
                errorTitle: fe.title,
                errorMessage: fe.text,
                errorDetail: fe.detail
            };
            this.isGenerating = false;
            return;
        }

        // Step 2a — non-auto-create: file already in source Files
        if (!isAutoCreate) {
            this.toast('Document generated', genResult.filename, 'success');
            // Skip auto-navigation in the new design — let the user see the
            // success card and click through deliberately. (Opt-in behavior
            // is more respectful of long sessions.)
            this.isGenerating = false;
            return;
        }

        // Step 2b — auto-create flow: keep the file pending while we
        // figure out where it should land.
        // outputFormat capture karte hain so we can route correctly later:
        //   DOCX/DOC → always S3 (via Lambda convertToPdf)
        //   PDF      → tier router (small=Tier1 Salesforce, larger=Tier2 S3)
        this._pendingFile = {
            filename: genResult.filename,
            base64: genResult.outputBase64,
            byteSize: genResult.byteSize,
            outputFormat: (genResult.outputFormat || '').toUpperCase()
        };

        // Look up ALL existing drafts (not just one) so we can show a table.
        let drafts = [];
        try {
            const raw = await listExistingDrafts({
                sourceRecordId: this.recordId,
                templateId: this.selectedTemplateId
            });
            drafts = (raw || []).map(d => this.formatDraftRow(d));
        } catch (e) {
            console.warn('[SignForce] listExistingDrafts failed (proceeding with new):', e);
            drafts = [];
        }

        if (drafts.length > 0) {
            // Stop here — show the panel and wait for the user's choice.
            this.existingDrafts = drafts;
            this.isGenerating = false;
            return;
        }

        // No existing drafts — proceed to create new immediately.
        await this.createNewAgreementWithPending();
        this.isGenerating = false;
    }

    /* ── User choices on the existing-drafts panel ──────────────── */

    /** User picked one of the existing drafts → attach file to it. */
    async handleUseExisting(e) {
        const targetId = e.currentTarget.dataset.id;
        if (!targetId || !this._pendingFile) return;

        this.isProcessingChoice = true;
        try {
            // Same router as new-agreement flow — DOCX→S3, PDF→tier router.
            await this.uploadPendingFileToAgreement(targetId);
            const picked = this.existingDrafts.find(d => d.id === targetId);
            this.agreementId = targetId;
            this.agreementName = picked ? picked.name : null;
            this.agreementWasReused = true;
            this.existingDrafts = [];     // hide the panel
            this._pendingFile = null;
            this.toast(
                'Document attached',
                'Saved to "' + (picked ? picked.name : 'existing agreement') + '".',
                'success'
            );
        } catch (err) {
            const msg = err?.body?.message || err?.message
                || 'Could not attach the document to the selected agreement';
            this.toast('Upload failed', msg, 'error');
        } finally {
            this.isProcessingChoice = false;
        }
    }

    /** User picked "Create new agreement" instead of using an existing draft. */
    async handleCreateNewAnyway() {
        if (!this._pendingFile) return;
        this.isProcessingChoice = true;
        try {
            await this.createNewAgreementWithPending();
        } finally {
            this.isProcessingChoice = false;
        }
    }

    /** User dismissed the panel without choosing — abort cleanly. */
    handleCancelChoice() {
        this.existingDrafts = [];
        this._pendingFile = null;
        this.result = null;        // reset back to the picker
        this.toast(
            'Cancelled',
            'Document was generated but not saved anywhere. Generate again to retry.',
            'info'
        );
    }

    /* ── Shared helper: create a fresh agreement and upload pending file ── */

    /**
     * Unified upload router for the generated file.
     *
     * Matches the createAgreement LWC's logic so both paths behave consistently:
     *
     *   DOC / DOCX (any size)   → AWS Lambda (action: convertToPdf) → S3 (Tier2)
     *                             Lambda converts to PDF + uploads to S3; we store
     *                             metadata as Agreement_Document__c with Storage_Tier=Tier2.
     *
     *   PDF, small (≤ tier1Max) → Salesforce ContentVersion (Tier1, existing flow)
     *   PDF, larger              → AWS Lambda (action: upload) → S3 (Tier2)
     *
     * Throws on failure so callers can show the proper toast.
     */
    async uploadPendingFileToAgreement(agreementId) {
        if (!this._pendingFile) throw new Error('No pending file to upload');
        if (!this._config) throw new Error('Storage config not loaded yet - try again in a moment.');

        const fmt = (this._pendingFile.outputFormat || '').toUpperCase();
        const isWord = fmt === 'DOCX' || fmt === 'DOC';

        if (isWord) {
            // Convert to PDF, then store in Salesforce Files (no S3).
            await this.uploadWordToSalesforce(agreementId);
            return;
        }

        // PDF → store in Salesforce Files (chunked, no S3).
        this._agreementPdfBase64 = this._pendingFile.base64;
        this._agreementPdfName = this._pendingFile.filename;
        await this.storeToSalesforceChunked(this._pendingFile.base64, this._pendingFile.filename, agreementId);
    }

    /* ── Convert DOC/DOCX → PDF via Lambda, then store the PDF in Salesforce ── */
    async uploadWordToSalesforce(agreementId) {
        if (!this._config.lambdaEndpoint) throw new Error('Lambda endpoint is not configured.');
        const res = await fetch(this._config.lambdaEndpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                action: 'convertToPdf',
                orgId: this._config.orgId,
                docId: `${agreementId}_${Date.now()}`,
                base64: this._pendingFile.base64,
                filename: this._pendingFile.filename,
                returnBase64: true
            })
        });
        if (!res.ok) { const t = await res.text(); throw new Error('Conversion failed: HTTP ' + res.status + ' ' + t.slice(0, 200)); }
        const json = await res.json();
        if (!json.success || !json.pdfBase64) throw new Error('Conversion did not return the PDF.');
        const pdfName = this._pendingFile.filename.replace(/\.(doc|docx)$/i, '.pdf');
        this._agreementPdfBase64 = json.pdfBase64;
        this._agreementPdfName = pdfName;
        await this.storeToSalesforceChunked(json.pdfBase64, pdfName, agreementId);
    }

    /* ── Chunk a base64 PDF into Salesforce Files, then wait for reassembly ── */
    async storeToSalesforceChunked(base64, fileName, agreementId) {
        const CHARS = 1000000;
        const sessionKey = `${agreementId}_${Date.now()}`;
        const total = Math.ceil(base64.length / CHARS);
        for (let i = 0; i < total; i++) {
            // eslint-disable-next-line no-await-in-loop
            await storeOriginalChunk({
                agreementId, sessionKey, chunkIndex: i, totalChunks: total,
                base64: base64.substring(i * CHARS, (i + 1) * CHARS), fileName
            });
        }
        for (let t = 0; t < 40; t++) {
            // eslint-disable-next-line no-await-in-loop
            if (await isOriginalReady({ agreementId })) return;
            // eslint-disable-next-line no-await-in-loop
            await new Promise(r => setTimeout(r, 1000));
        }
        throw new Error('The document is taking too long to finalize. Please try again.');
    }

    /**
     * Word path: send base64 to Lambda, which converts DOCX→PDF and uploads
     * the result to S3. Same Lambda action as createAgreement uses.
     * After Lambda confirms, we persist an Agreement_Document__c row pointing
     * at the S3 object (Storage_Tier=Tier2).
     */
    async uploadWordViaLambda(agreementId) {
        if (!this._config.lambdaEndpoint) {
            throw new Error(
                'Lambda endpoint is not configured. Ask your admin to set ' +
                'Lambda_Endpoint__c on the SignForce_Config__mdt "Default" record.'
            );
        }
        const docId = `${agreementId}_${Date.now()}`;
        const res = await fetch(this._config.lambdaEndpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                action: 'convertToPdf',
                orgId: this._config.orgId,
                docId: docId,
                base64: this._pendingFile.base64,
                filename: this._pendingFile.filename
            })
        });
        if (!res.ok) {
            const txt = await res.text();
            throw new Error('Conversion failed: HTTP ' + res.status + ' ' + txt.slice(0, 200));
        }
        const json = await res.json();
        if (!json.success || !json.url) {
            throw new Error('Lambda did not return a valid S3 URL');
        }

        // Filename ends in .pdf since Lambda converted the Word file.
        const pdfFileName = this._pendingFile.filename.replace(/\.(doc|docx)$/i, '.pdf');
        await createAgreementDocumentS3({
            agreementId: agreementId,
            s3DocId: docId,
            s3Url: json.url,
            fileName: pdfFileName,
            fileSize: json.size || this._pendingFile.byteSize || 0,
            tier: 'Tier2'
        });
        // Preview source for the agreement-success card "View File" button.
        this.agreementPreviewUrl = vfPageUrl('PDFPreview') + '?pdfUrl='
            + encodeURIComponent(json.url) + '&ts=' + Date.now();
        this._agreementPdfName = pdfFileName;
    }

    /**
     * PDF path: single POST → Lambda → S3 (Tier2 single-shot upload).
     * Used when generated PDF is larger than Tier1 threshold. We use Tier2
     * single-shot (not Tier3 chunked) because the file is already in memory
     * as base64 — chunking from a base64 string adds complexity without
     * meaningful benefit for files in the typical generation size range.
     */
    async uploadPdfToS3(agreementId) {
        if (!this._config.lambdaEndpoint) {
            throw new Error(
                'Lambda endpoint is not configured. Ask your admin to set ' +
                'Lambda_Endpoint__c on the SignForce_Config__mdt "Default" record.'
            );
        }
        const docId = `${agreementId}_${Date.now()}`;
        const res = await fetch(this._config.lambdaEndpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                action: 'upload',
                orgId: this._config.orgId,
                docId: docId,
                pdfBase64: this._pendingFile.base64
            })
        });
        if (!res.ok) {
            const txt = await res.text();
            throw new Error('Lambda upload failed: HTTP ' + res.status + ' ' + txt.slice(0, 200));
        }
        const json = await res.json();
        if (!json.url) {
            throw new Error('Lambda did not return a valid S3 URL');
        }
        await createAgreementDocumentS3({
            agreementId: agreementId,
            s3DocId: docId,
            s3Url: json.url,
            fileName: this._pendingFile.filename,
            fileSize: this._pendingFile.byteSize || 0,
            tier: 'Tier2'
        });
        // Preview source for the agreement-success card "View File" button.
        this.agreementPreviewUrl = vfPageUrl('PDFPreview') + '?pdfUrl='
            + encodeURIComponent(json.url) + '&ts=' + Date.now();
        this._agreementPdfName = this._pendingFile.filename;
    }

    /** Title for the failure card; the translated one when we have it. */
    get resultErrorTitle() {
        return this.result?.errorTitle || 'Generation failed';
    }

    async createNewAgreementWithPending() {
        if (!this._pendingFile) return;
        const tpl = this.selectedTemplate;
        const agreementName = this.stripExtension(this._pendingFile.filename) ||
            (tpl && tpl.Name) || 'New Agreement';
        try {
            const newAgreementId = await createAgreement({
                name: agreementName,
                agreementType: (tpl && tpl.Default_Agreement_Type__c) || 'Other',
                signingOrder: 'Sequential',
                message: '',
                expiryDate: null
            });

            // Tag with source record + template + the generation run that
            // produced it (best-effort, non-fatal). The log id is what lets the
            // history screen put "Open Agreement" on the RIGHT row instead of
            // guessing the pairing from template + creation order.
            try {
                await tagAgreementSource({
                    agreementId: newAgreementId,
                    sourceRecordId: this.recordId,
                    templateId: this.selectedTemplateId,
                    generationLogId: this.result?.logId || null
                });
            } catch (tagErr) {
                console.warn('[SignForce] tagAgreementSource failed (non-fatal):', tagErr);
            }

            // Upload the file — DOCX/DOC always go to S3 via Lambda,
            // PDF routes by size (Tier1 = Salesforce, Tier2 = S3).
            try {
                await this.uploadPendingFileToAgreement(newAgreementId);
            } catch (uploadErr) {
                const uploadMsg = uploadErr?.body?.message || uploadErr?.message
                    || 'Could not attach the document to the new agreement';
                // Agreement was created but file didn't attach — show the
                // success-with-warning view so the user can recover manually.
                this.agreementId = newAgreementId;
                this.agreementName = agreementName;
                this.existingDrafts = [];
                this._pendingFile = null;
                this.toast(
                    'Agreement created - file upload failed',
                    uploadMsg + ' (You can upload it manually inside the agreement.)',
                    'warning'
                );
                return;
            }

            // Materialize the template's pre-defined signers (and any
            // reserved fields) onto the brand-new agreement, applying the
            // STEP-2 signer-email mapping. Best-effort and non-fatal — a
            // failure here must NOT lose the created agreement or its attached
            // document, so we swallow/warn exactly like tagAgreementSource above.
            //
            // When the template has signers and/or UNASSIGNED fields we pass
            // the STEP-2 mapping as
            //   { signers: { [key]: { name, email } }, fieldEmails: { [idx]: email } };
            // when it has neither we pass '{}' so the Apex no-ops the override
            // and behaves exactly as the original 2-arg materialize did.
            try {
                const mappingJson = this.hasTemplateSigners
                    ? JSON.stringify(this._buildSignerMapping())
                    : '{}';
                await materializeSignersAndFieldsMapped({
                    agreementId: newAgreementId,
                    templateId: this.selectedTemplateId,
                    mappingJson: mappingJson
                });
            } catch (matErr) {
                console.warn('[SignForce] materializeSignersAndFieldsMapped failed (non-fatal):', matErr);
            }

            // Pre-fill interactive fields (Email / Full Name / Company / Title)
            // with the values known now, so the signer sees them filled in rather
            // than empty. Additive and non-fatal — only blank fields are touched,
            // so a failure changes nothing.
            try {
                await prefillAgreementFields({
                    agreementId: newAgreementId,
                    recordId: this.recordId
                });
            } catch (preErr) {
                console.warn('[SignForce] prefillAgreementFields failed (non-fatal):', preErr);
            }

            // Re-place any anchored fields on the merged document so they track
            // content reflow (zero-drift). Fully isolated + best-effort: any
            // failure leaves the materialized absolute positions untouched.
            try {
                await this.resolveAnchoredFields(newAgreementId, this.selectedTemplateId, this.recordId);
            } catch (anchorErr) {
                console.warn('[SignForce] resolveAnchoredFields failed (non-fatal):', anchorErr);
            }

            // Success — flip into the agreement-result card.
            this.agreementId = newAgreementId;
            this.agreementName = agreementName;
            this.agreementWasReused = false;
            this.existingDrafts = [];
            this._pendingFile = null;
            this.toast('Agreement created', agreementName, 'success');

        } catch (err) {
            const msg = err?.body?.message || err?.message
                || 'Could not create the agreement record';
            this.agreementErrorMessage = msg;
            this.existingDrafts = [];
            this._pendingFile = null;
            this.toast(
                'Agreement could not be created',
                msg + ' Document was generated but not saved.',
                'error'
            );
        }
    }

    openAgreement() {
        if (!this.agreementId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.agreementId,
                objectApiName: 'Agreement__c',
                actionName: 'view'
            }
        });
    }

    /* ── Preview (unchanged) ────────────────────────────────────── */

    refreshPreview() {
        const t = this.selectedTemplate;
        if (!t || !this._record) {
            this.previewRows = [];
            return;
        }
        this.previewLoading = true;
        this.previewError = null;
        try {
            const rows = (t.Template_Fields__r || []).map(field => {
                const tag = field.Tag_Name__c;
                const type = field.Field_Type__c;
                const display = this.resolvePreviewValue(tag, type);
                return {
                    tag, type,
                    typeClass: 'sf-tag-type sf-tag-type-' + (type || 'Field').toLowerCase(),
                    display
                };
            });
            this.previewRows = rows;
        } catch (e) {
            this.previewError = 'Preview unavailable: ' + e.message;
        } finally {
            this.previewLoading = false;
        }
    }

    resolvePreviewValue(tag, type) {
        if (type === 'Builtin') {
            if (tag === 'TODAY') return new Date().toISOString().slice(0, 10);
            if (tag === 'NOW') return new Date().toISOString();
            return '(resolved at generation)';
        }
        if (type === 'Loop') return '(child records - resolved at generation)';
        if (type === 'Image') return '(image URL - resolved at generation)';

        const fields = this._record.fields || {};
        if (fields[tag]) return this.formatValue(fields[tag].value);

        const parts = tag.split('.');
        let cursor = fields[parts[0]];
        for (let i = 1; i < parts.length; i++) {
            if (!cursor) break;
            const next = cursor.value && cursor.value.fields
                ? cursor.value.fields[parts[i]]
                : null;
            cursor = next;
        }
        if (cursor && cursor.value !== undefined) return this.formatValue(cursor.value);
        return '(resolved at generation)';
    }

    formatValue(v) {
        if (v === null || v === undefined || v === '') return '-';
        if (typeof v === 'object') return '(object)';

        // Issue #11 fix — previously dates/datetimes were shown in raw ISO
        // form ("2025-05-15T10:00:00.000Z") which is unreadable. If the
        // value looks like an ISO timestamp, format it for the user locale.
        if (typeof v === 'string') {
            // Date only: YYYY-MM-DD
            if (/^\d{4}-\d{2}-\d{2}$/.test(v)) {
                try {
                    // Parse as local date (avoid timezone shifting back a day)
                    const [y, m, d] = v.split('-').map(Number);
                    return new Date(y, m - 1, d).toLocaleDateString();
                } catch (e) { /* fall through */ }
            }
            // DateTime: ISO 8601 with T
            if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(v)) {
                try {
                    const dt = new Date(v);
                    if (!isNaN(dt.getTime())) return dt.toLocaleString();
                } catch (e) { /* fall through */ }
            }
        }

        return String(v);
    }

    /* ── Helpers ────────────────────────────────────────────────── */

    stripExtension(filename) {
        if (!filename) return filename;
        const dot = filename.lastIndexOf('.');
        return dot > 0 ? filename.substring(0, dot) : filename;
    }

    /**
     * Format a draft row from Apex into something the table renders well.
     * Adds a relative-time label ("2 hours ago") so the user can quickly
     * see which is the most recent.
     */
    formatDraftRow(d) {
        return {
            id: d.id,
            name: d.name,
            createdBy: d.createdBy || '-',
            relativeDate: this.relativeTime(d.createdDate),
            hasDocument: !!d.hasDocument
        };
    }

    relativeTime(iso) {
        if (!iso) return '-';
        const then = new Date(iso);
        const now = new Date();
        const ms = now - then;
        if (isNaN(ms)) return '-';
        const sec = Math.round(ms / 1000);
        if (sec < 60) return sec <= 5 ? 'Just now' : sec + ' seconds ago';
        const min = Math.round(sec / 60);
        if (min < 60) return min === 1 ? '1 minute ago' : min + ' minutes ago';
        const hr = Math.round(min / 60);
        if (hr < 24) return hr === 1 ? '1 hour ago' : hr + ' hours ago';
        const day = Math.round(hr / 24);
        if (day < 30) return day === 1 ? 'Yesterday' : day + ' days ago';
        // Fall back to a plain date for older entries
        return then.toLocaleDateString();
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
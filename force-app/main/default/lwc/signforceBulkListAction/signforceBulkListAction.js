import { LightningElement, api, track } from 'lwc';
import { stripNs } from 'c/nsUtils';
import { friendlyError } from 'c/signforceErrors';

import listTemplates from '@salesforce/apex/TemplateService.listTemplates';
import describeIds from '@salesforce/apex/SignForceBulkGenerate.describeIds';
import startBulkGenerate from '@salesforce/apex/SignForceBulkGenerate.startBulkGenerate';
import getGenerateStatus from '@salesforce/apex/SignForceBulkGenerate.getGenerateStatus';

const POLL_MS = 2500;

/* How many records are listed by name before the list collapses behind a
   "show all" toggle, and how many outcomes are listed one by one afterwards. */
const NAME_PREVIEW = 8;
const RESULT_LIMIT = 25;

/**
 * signforceBulkListAction — bulk document generation over a pre-selected set of
 * records.
 *
 * Runs as a FLOW SCREEN COMPONENT. The list view button is a URL button
 * pointing at the SignForce_Bulk_Generate_Documents screen flow; the platform
 * hands the ticked rows to the flow's `ids` collection, and the flow passes
 * them here as flowRecordIds. That replaces the earlier Visualforce +
 * Lightning Out host — no $Lightning bootstrap, and one flow serves every
 * object because the object is derived from the ids themselves (describeIds).
 *
 * The legacy string form (recordIds, comma-separated) is still accepted so the
 * old Visualforce host keeps working wherever it is already wired.
 *
 * No ShowToastEvent anywhere: inside a flow screen there is no toast container,
 * so every message renders in the component's own markup.
 *
 * DESIGN NOTE. Arriving from a list-view button, the user has no page context —
 * no record, no breadcrumb, nothing that says what the button was about to do.
 * So the screen states it: what was selected (by name, not just a count), what
 * will be produced, and, when the button is off, why. Every one of those
 * answers a question the earlier version left the reader to guess.
 */
export default class SignforceBulkListAction extends LightningElement {

    /** From the flow: the `ids` text collection, passed straight through. */
    @api
    get flowRecordIds() { return this._flowIds; }
    set flowRecordIds(value) {
        this._flowIds = value;
        if (Array.isArray(value) && value.length) {
            this._ids = value.filter((s) => s && s.length >= 15);
            this.resolveObject();
        }
    }

    /** Legacy: comma-separated ids from the Visualforce host. */
    @api
    get recordIds() { return this._raw; }
    set recordIds(value) {
        this._raw = value || '';
        if (this._raw) {
            this._ids = this._raw.split(',').map((s) => s.trim()).filter((s) => s.length >= 15);
            this.resolveObject();
        }
    }

    /** Legacy: explicit object name from the Visualforce host. Auto-detected otherwise. */
    @api objectApiName;

    _flowIds = [];
    _raw = '';
    _ids = [];

    @track objectInfo = null;      // { objectApiName, objectLabel, objectLabelPlural, records }
    @track templates = [];
    @track selectedTemplateId = null;
    @track isLoading = true;
    @track running = false;
    @track batch = null;
    @track showAllRecords = false;
    @track fault = null;           // { title, text, detail } from friendlyError
    @track showFaultDetail = false;

    _poll = null;
    _startedAt = null;
    _objectResolved = false;

    connectedCallback() {
        // Ids may already have arrived through a setter before connect; if not,
        // this is a no-op and the setter triggers it later.
        this.resolveObject();
    }

    disconnectedCallback() {
        clearInterval(this._poll);
        this._poll = null;
    }

    /**
     * Works out which object the ids belong to, then loads that object's
     * templates. Guarded so the two setters plus connectedCallback trigger it
     * only once per set of ids.
     */
    async resolveObject() {
        if (this._objectResolved || this._ids.length === 0) {
            this.isLoading = this._ids.length > 0;
            if (this._ids.length === 0) this.isLoading = false;
            return;
        }
        this._objectResolved = true;
        this.isLoading = true;

        try {
            if (this.objectApiName) {
                // Old host told us explicitly — trust it, but there are no
                // record names on this path, so the list falls back to ids.
                this.objectInfo = {
                    objectApiName: this.objectApiName,
                    objectLabel: this.friendly(this.objectApiName),
                    objectLabelPlural: this.friendly(this.objectApiName) + 's',
                    records: this._ids.map((id) => ({ id, name: id }))
                };
            } else {
                this.objectInfo = await describeIds({ recordIds: this._ids });
            }
            await this.loadTemplates();
        } catch (e) {
            this.fault = friendlyError(e);
        } finally {
            this.isLoading = false;
        }
    }

    async loadTemplates() {
        const objName = this.objectInfo && this.objectInfo.objectApiName;
        if (!objName) { this.templates = []; return; }

        const rows = await listTemplates();
        this.templates = (rows || [])
            .map((r) => stripNs(r))
            .filter((t) =>
                t.Active__c !== false &&
                t.Template_File_Id__c &&
                (t.Object_API_Name__c || '').toLowerCase() === objName.toLowerCase()
            );
        // One choice is not a choice — pre-select it so the run button is live
        // the moment the screen opens.
        if (this.templates.length === 1) {
            this.selectedTemplateId = this.templates[0].Id;
        }
    }

    friendly(apiName) {
        return (apiName || 'record').replace(/__c$/i, '').replace(/_/g, ' ');
    }

    /* ── selection ── */

    get recordCount() { return this._ids.length; }
    get hasNoRecords() { return !this.isLoading && this._ids.length === 0; }
    get hasTemplates() { return this.templates.length > 0; }
    get hasError() { return !!this.fault; }

    /**
     * The raw Apex text stays available but stays folded away. Hiding it
     * entirely would leave an admin with nothing to diagnose from; showing it
     * by default is what made the old screen unreadable.
     */
    get faultDetailLabel() {
        return this.showFaultDetail ? 'Hide technical details' : 'Show technical details';
    }
    toggleFaultDetail() { this.showFaultDetail = !this.showFaultDetail; }

    get objectLabelSingular() {
        return (this.objectInfo && this.objectInfo.objectLabel) || 'record';
    }

    get objectLabelPlural() {
        if (!this.objectInfo) return 'records';
        return this.objectInfo.objectLabelPlural || this.objectInfo.objectLabel + 's';
    }

    /** Singular or plural to match the count. */
    get objectLabel() {
        return this.recordCount === 1 ? this.objectLabelSingular : this.objectLabelPlural;
    }

    get allRecords() {
        return (this.objectInfo && this.objectInfo.records) || [];
    }

    get visibleRecords() {
        return this.showAllRecords ? this.allRecords : this.allRecords.slice(0, NAME_PREVIEW);
    }

    get hasMoreRecords() { return this.allRecords.length > NAME_PREVIEW; }

    get moreLabel() {
        return this.showAllRecords
            ? 'Show fewer'
            : `+${this.allRecords.length - NAME_PREVIEW} more`;
    }

    toggleAllRecords() { this.showAllRecords = !this.showAllRecords; }

    /* ── copy ── */

    get headerSubtitle() {
        if (this.isLoading) return 'Reading your selection…';
        if (this.hasNoRecords) return 'Nothing was selected in the list.';
        return `One document for every ${this.objectLabelSingular.toLowerCase()} you ticked.`;
    }

    get recordsSubtitle() {
        return this.recordCount === 1
            ? `The ${this.objectLabelSingular.toLowerCase()} you ticked in the list.`
            : `The ${this.objectLabelPlural.toLowerCase()} you ticked in the list.`;
    }

    get templateSubtitle() {
        if (!this.hasTemplates) return 'Nothing is available for this kind of record.';
        if (this.templates.length === 1) return 'Only one applies here, so it is already chosen.';
        return `${this.templates.length} templates apply to ${this.objectLabelPlural.toLowerCase()}.`;
    }

    get runSubtitle() {
        if (this.finished) return 'Finished.';
        if (this.batch) return 'Working through the list.';
        return 'Check what is about to happen, then start.';
    }

    /** The whole outcome in one sentence, before anything is created. */
    get planSentence() {
        const t = this.selectedTemplate;
        if (!t) return '';
        const n = this.recordCount;
        const noun = n === 1 ? 'document' : 'documents';
        const obj = n === 1 ? this.objectLabelSingular.toLowerCase() : this.objectLabelPlural.toLowerCase();
        return `${n} ${t.format} ${noun} will be created — one for each of the ${n} ${obj} above.`;
    }

    get startLabel() {
        const n = this.recordCount;
        return n === 1 ? 'Generate 1 document' : `Generate ${n} documents`;
    }

    /**
     * Why the button is off. A disabled control with no explanation is the
     * single most common reason someone concludes a screen is broken.
     */
    get blockReason() {
        if (this.running || this.batch) return '';
        if (!this.selectedTemplateId) return 'Pick a document above to continue.';
        return '';
    }

    /* ── templates ── */

    get templateCards() {
        return this.templates.map((t) => {
            const on = t.Id === this.selectedTemplateId;
            const tags = (t.Template_Fields__r || []).length;
            const format = t.Output_Format__c || 'DOCX';
            return {
                id: t.Id,
                name: t.Name,
                metaLabel: tags
                    ? `${format} · ${tags} merge ${tags === 1 ? 'tag' : 'tags'}`
                    : `${format} · no merge tags`,
                selected: on,
                selectedStr: String(on),
                cardClass: on ? 'bla-card bla-card-on' : 'bla-card'
            };
        });
    }

    get selectedTemplate() {
        const t = this.templates.find((x) => x.Id === this.selectedTemplateId);
        return t ? { name: t.Name, format: t.Output_Format__c || 'DOCX' } : null;
    }

    handleTemplateCard(e) {
        if (this.locked) return;
        this.selectedTemplateId = e.currentTarget.dataset.id;
        this.fault = null;
    }

    /** Once a run has started the choice is history, not an option. */
    get locked() { return this.running || !!this.batch; }

    get step2NumClass() {
        return this.selectedTemplateId ? 'bla-num bla-num-done' : 'bla-num';
    }
    get step3NumClass() {
        if (this.finished) return 'bla-num bla-num-done';
        return this.selectedTemplateId ? 'bla-num' : 'bla-num bla-num-idle';
    }

    /* ── run state ── */

    get startDisabled() { return this.running || !this.selectedTemplateId; }
    get finished() { return !!this.batch && this.batch.finished; }
    get hasFailures() { return !!this.batch && this.batch.failed > 0; }

    get queued() {
        if (!this.batch) return 0;
        return Math.max(0, this.batch.total - this.batch.done);
    }
    get hasQueued() { return this.queued > 0; }

    get percent() {
        if (!this.batch || !this.batch.total) return 0;
        return Math.round((this.batch.done / this.batch.total) * 100);
    }
    get barStyle() { return `width:${this.percent}%`; }

    get progressLabel() {
        if (!this.batch) return '';
        if (this.finished) return 'All records processed';
        return `${this.batch.done} of ${this.batch.total} processed`;
    }

    _nameFor(recordId) {
        const hit = this.allRecords.find((r) => r.id === recordId);
        return (hit && hit.name) || recordId;
    }

    /**
     * One line per record. Past RESULT_LIMIT records the list would be longer
     * than the screen, so it narrows to the failures — which are the only rows
     * anyone needs to act on — and says so.
     */
    get resultRows() {
        const rows = (this.batch && this.batch.rows) || [];
        const compact = rows.length > RESULT_LIMIT;
        return rows
            .filter((r) => !compact || r.status === 'Failure')
            .map((r) => {
                const ok = r.status === 'Success';
                const bad = r.status === 'Failure';
                const open = bad && this._openRows.includes(r.recordId);
                return {
                    recordId: r.recordId,
                    name: this._nameFor(r.recordId),
                    // Error_Message__c is "<TypeName>: <message>" followed by a
                    // stack trace. Printed as-is it is unreadable, so the row
                    // carries the explanation instead — with the original one
                    // click away, because the explanation cannot cover every
                    // failure and an admin still needs the real text.
                    error: bad ? friendlyError(r.error).text : '',
                    hasRaw: bad && !!r.error,
                    showRaw: open,
                    rawError: r.error || '',
                    rawLabel: open ? 'Hide technical details' : 'Show technical details',
                    stateLabel: ok ? 'Created' : (bad ? 'Failed' : 'Waiting'),
                    rowClass: bad ? 'bla-result bla-result-bad' : 'bla-result',
                    dotClass: ok ? 'bla-dot bla-dot-ok'
                        : (bad ? 'bla-dot bla-dot-bad' : 'bla-dot bla-dot-wait')
                };
            });
    }

    get showResultRows() { return this.resultRows.length > 0; }

    /* Record ids whose raw error is expanded. Kept here rather than on the row
       objects because resultRows is rebuilt from the poll on every tick. */
    @track _openRows = [];

    toggleRowRaw(e) {
        const id = e.currentTarget.dataset.id;
        this._openRows = this._openRows.includes(id)
            ? this._openRows.filter((x) => x !== id)
            : [...this._openRows, id];
    }

    get resultsNote() {
        const total = (this.batch && this.batch.rows && this.batch.rows.length) || 0;
        return total > RESULT_LIMIT
            ? 'Only the records that failed are listed — there are too many to show every one.'
            : '';
    }
    get hasResultsNote() { return !!this.resultsNote; }

    get doneMessage() {
        if (!this.batch) return '';
        const { succeeded, failed } = this.batch;
        if (!failed) {
            return succeeded === 1
                ? 'Done. 1 document was created.'
                : `Done. All ${succeeded} documents were created.`;
        }
        return `${succeeded} created, ${failed} could not be. The reason is next to each one above — fix it and run those records again.`;
    }

    get doneClass() {
        return this.hasFailures ? 'bla-done bla-done-warn' : 'bla-done bla-done-ok';
    }

    /* ── actions ── */

    async handleStart() {
        if (this.startDisabled) return;
        this.running = true;
        this.fault = null;
        this.batch = null;
        try {
            const res = await startBulkGenerate({
                templateId: this.selectedTemplateId,
                recordIds: this._ids
            });
            this._startedAt = res.startedAt;
            this.batch = {
                total: res.total, done: 0, succeeded: 0, failed: 0,
                finished: false,
                // Seed every record as Waiting so the list appears immediately
                // rather than after the first poll two and a half seconds later.
                rows: this._ids.map((id) => ({ recordId: id, status: 'Waiting', error: null }))
            };
            this.poll();
        } catch (e) {
            this.running = false;
            this.fault = friendlyError(e);
        }
    }

    poll() {
        clearInterval(this._poll);
        this._poll = setInterval(async () => {
            try {
                const s = await getGenerateStatus({
                    templateId: this.selectedTemplateId,
                    recordIds: this._ids,
                    startedAtIso: this._startedAt
                });
                this.batch = s;
                if (s.finished) {
                    clearInterval(this._poll);
                    this._poll = null;
                    this.running = false;
                }
            } catch (e) {
                // Batch is server-side; a dropped poll changes nothing.
                console.warn('[SignForce] list-action poll failed', e);
            }
        }, POLL_MS);
    }

    /* ── leaving ── */

    /**
     * Back to the list the user came from.
     *
     * The flow screen's own footer is switched off (see the flow metadata), so
     * this is the only way out and it has to land somewhere useful. The Finish
     * button it replaces ended the interview but left the reader sitting on the
     * flow runtime page, and the retURL on the list-view button is not honoured
     * reliably by the Lightning flow runtime.
     *
     * Leaving mid-run is safe: the batch is server-side and keeps going.
     */
    /**
     * The address of the object's list view, put straight on an <a href>.
     *
     * NO JAVASCRIPT. Two earlier attempts failed here and both failed silently:
     * NavigationMixin.Navigate fires an event that nothing inside a flow screen
     * handles, and window.location / window.open are restricted by Lightning
     * Web Security depending on the container, so every branch threw and the
     * click did nothing at all. A plain link needs no API to be granted — the
     * browser follows it. This is the same fix that made the sample-CSV
     * download work.
     *
     * target="_top" is on the links: a flow launched from a list-view button
     * can be hosted in an iframe, where a normal link would navigate the frame
     * and leave the page around it untouched.
     */
    get listUrl() {
        const objectApiName = this.objectInfo && this.objectInfo.objectApiName;
        // The API name already carries any namespace, so this needs no escaping.
        return objectApiName ? `/lightning/o/${objectApiName}/list` : '/lightning/page/home';
    }

    get leaveLabel() {
        return this.finished ? 'Back to the list' : 'Leave it running';
    }

    /* Once the run is done, leaving IS the next step, so it takes the primary
       treatment. While it is still working, leaving is a choice, not the
       expected one. */
    get leaveButtonClass() {
        return this.finished
            ? 'bla-btn bla-btn-primary bla-link'
            : 'bla-btn bla-btn-ghost bla-link';
    }


}
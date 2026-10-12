import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { stripNs } from 'c/nsUtils';
import { friendlyError } from 'c/signforceErrors';

import listTemplates from '@salesforce/apex/TemplateService.listTemplates';
import searchRecords from '@salesforce/apex/SignForceBulkGenerate.searchRecords';
import startBulkGenerate from '@salesforce/apex/SignForceBulkGenerate.startBulkGenerate';
import getGenerateStatus from '@salesforce/apex/SignForceBulkGenerate.getGenerateStatus';
import getRecentActivity from '@salesforce/apex/SignForceBulkGenerate.getRecentActivity';
import getActivityDetail from '@salesforce/apex/SignForceBulkGenerate.getActivityDetail';

import listMasterAgreements from '@salesforce/apex/SignForceBulkSend.listMasterAgreements';
import startBulkSend from '@salesforce/apex/SignForceBulkSend.startBulkSend';
import getBulkStatus from '@salesforce/apex/SignForceBulkSend.getBulkStatus';

const POLL_MS = 2500;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

const BOM = '\uFEFF';
const MAX_CSV_BYTES = 1024 * 1024;
const MAX_CSV_ROWS = 200;

/* Failed records listed one by one before the list defers to the log tab. */
const FAIL_LIMIT = 12;

/* Matches the LIMIT in getActivityDetail — the note only appears when the
   server actually had more to give. */
const DETAIL_LIMIT = 200;

/* Documents per page inside an expanded activity row. Without this a busy
   template rendered 43 rows in one go and buried the rest of the console. */
const DETAIL_PAGE = 10;

// The headings here are the ones the importer looks for, so the sample doubles
// as the documentation for the format.
const SAMPLE_CSV =
    'Name,Email\r\n' +
    'Jane Cooper,jane.cooper@example.com\r\n' +
    'Ravi Patel,ravi.patel@example.com\r\n' +
    'Aisha Khan,aisha.khan@example.com\r\n';

/**
 * signforceBulkConsole — one screen for the two bulk jobs.
 *
 *   Generate documents  one template across many records
 *   Send for signature  one agreement copied to many recipients
 *
 * Both are queued server-side and report progress by polling, so the batch keeps
 * running whether or not this tab stays open. Neither introduces a new way to
 * produce a document: they call the same generate() and the same clone-and-send
 * the single-record buttons use.
 */
export default class SignforceBulkConsole extends LightningElement {

    @track mode = 'generate';

    /* ── generate ── */
    @track templates = [];
    @track selectedTemplateId = null;
    @track records = [];
    @track searchTerm = '';
    @track isSearching = false;
    @track genRunning = false;
    @track genBatch = null;

    _selectedIds = new Set();
    _searchTimer = null;
    _genPoll = null;
    _genStartedAt = null;
    _genRecordIds = [];
    _runTemplateName = '';
    _runObjectName = '';

    /* ── send ── */
    @track agreements = [];
    @track selectedAgreementId = null;
    // One entry per recipient row: { key, name, email }. Seeded in
    // connectedCallback so the panel opens with a row ready to type into.
    @track _rows = [];
    @track showPaste = false;
    @track pasteRaw = '';
    @track sendRunning = false;
    @track sendBatch = null;

    _sendPoll = null;
    _sendBatchId = null;

    @track activity = [];
    @track activityLoading = true;

    /* The last failure, kept on screen rather than thrown at a toast. */
    @track fault = null;
    @track showFaultDetail = false;

    connectedCallback() {
        this._rows = [this.newRow(), this.newRow()];
        this.loadTemplates();
        this.loadAgreements();
        this.loadActivity();
    }

    disconnectedCallback() {
        // Polls outlive the component otherwise and keep hitting the server after
        // the user has navigated away.
        this.stopPolling();
    }

    stopPolling() {
        clearInterval(this._genPoll);
        clearInterval(this._sendPoll);
        clearTimeout(this._searchTimer);
        this._genPoll = null;
        this._sendPoll = null;
    }

    /* ── mode ── */

    get isGenerate() { return this.mode === 'generate'; }
    get isSend() { return this.mode === 'send'; }
    get generateTabClass() { return this.isGenerate ? 'bc-tab bc-tab-on' : 'bc-tab'; }
    get sendTabClass() { return this.isSend ? 'bc-tab bc-tab-on' : 'bc-tab'; }

    handleMode(e) {
        this.mode = e.currentTarget.dataset.mode;
    }

    /* ══════════════ GENERATE ══════════════ */

    async loadTemplates() {
        try {
            const rows = await listTemplates();
            this.templates = (rows || []).map((r) => stripNs(r))
                .filter((t) => t.Active__c !== false && t.Template_File_Id__c);
        } catch (e) {
            this.fail(e);
        }
    }

    get hasTemplates() { return this.templates.length > 0; }

    get templateCards() {
        return this.templates.map((t) => {
            const on = t.Id === this.selectedTemplateId;
            // Template_Fields__r comes back from listTemplates as a subquery, so
            // the merge-tag count is already here — no extra round trip.
            const tags = (t.Template_Fields__r || []).length;
            return {
                id: t.Id,
                name: t.Name,
                object: t.Object_API_Name__c,
                format: t.Output_Format__c || 'DOCX',
                tagCount: tags,
                hasTags: tags > 0,
                selected: on,
                selectedStr: String(on),
                cardClass: on ? 'bc-tpl bc-tpl-on' : 'bc-tpl'
            };
        });
    }

    /** Distinct objects across the runnable templates. */
    get statObjects() {
        return new Set(this.templates.map((t) => t.Object_API_Name__c)).size;
    }

    /** Documents generated in the window the activity table already covers. */
    get statWeekDocs() {
        return this.activity.reduce((sum, a) => sum + (a.succeeded || 0), 0);
    }

    handleTemplateCard(e) {
        this.selectTemplate(e.currentTarget.dataset.id);
    }

    /* Cards are radios, so they have to answer Enter and Space like one. */
    handleTemplateKey(e) {
        if (e.key !== 'Enter' && e.key !== ' ') return;
        e.preventDefault();
        this.selectTemplate(e.currentTarget.dataset.id);
    }

    selectTemplate(id) {
        if (!id || id === this.selectedTemplateId) return;
        this.selectedTemplateId = id;
        this._selectedIds = new Set();   // different object, nothing carries over
        this.searchTerm = '';
        this.genBatch = null;
        this.loadRecords();
    }

    get selectedTemplate() {
        const t = this.templates.find((x) => x.Id === this.selectedTemplateId);
        if (!t) return null;
        return { object: t.Object_API_Name__c, format: t.Output_Format__c || 'DOCX' };
    }

    handleTemplateChange(e) {
        this.selectedTemplateId = e.detail.value;
        // A different template means a different object, so nothing selected so
        // far can still be valid.
        this._selectedIds = new Set();
        this.searchTerm = '';
        this.genBatch = null;
        this.loadRecords();
    }

    handleSearch(e) {
        this.searchTerm = e.target.value;
        // Debounced: a query per keystroke would be one SOQL per letter typed.
        clearTimeout(this._searchTimer);
        this._searchTimer = setTimeout(() => this.loadRecords(), 350);
    }

    async loadRecords() {
        if (!this.selectedTemplateId) return;
        this.isSearching = true;
        try {
            const rows = await searchRecords({
                templateId: this.selectedTemplateId,
                term: this.searchTerm
            });
            this.records = (rows || []).map((r) => this.decorate(r));
        } catch (e) {
            this.records = [];
            this.fail(e);
        } finally {
            this.isSearching = false;
        }
    }

    decorate(r) {
        const selected = this._selectedIds.has(r.id);
        return {
            id: r.id,
            name: r.name,
            selected,
            rowClass: selected ? 'bc-rec bc-rec-on' : 'bc-rec'
        };
    }

    /* Re-decorates in place so the checkbox state survives a re-search. */
    repaintRecords() {
        this.records = this.records.map((r) => this.decorate(r));
    }

    handleToggleRecord(e) {
        const id = e.target.dataset.id;
        if (e.target.checked) this._selectedIds.add(id);
        else this._selectedIds.delete(id);
        this.repaintRecords();
    }

    selectAllVisible() {
        this.records.forEach((r) => this._selectedIds.add(r.id));
        this.repaintRecords();
    }

    clearSelection() {
        this._selectedIds = new Set();
        this.repaintRecords();
    }

    get hasRecords() { return this.records.length > 0; }
    get visibleCount() { return this.records.length; }
    get selectedCount() { return this._selectedIds.size; }
    get hasSelection() { return this.selectedCount > 0; }

    get selectedCountLabel() {
        const n = this.selectedCount;
        return n === 1 ? '1 selected' : `${n} selected`;
    }

    get generateDisabled() { return this.genRunning || this.selectedCount === 0; }

    async handleStartGenerate() {
        const ids = Array.from(this._selectedIds);
        if (!ids.length) return;

        this.genRunning = true;
        this.genBatch = null;

        // Pinned now, so the progress panel keeps describing THIS run even if the
        // template picker is changed while it is going.
        const tpl = this.templates.find((t) => t.Id === this.selectedTemplateId);
        this._runTemplateName = tpl ? tpl.Name : '';
        this._runObjectName = tpl ? tpl.Object_API_Name__c : '';

        try {
            const res = await startBulkGenerate({
                templateId: this.selectedTemplateId,
                recordIds: ids
            });
            this._genStartedAt = res.startedAt;
            this._genRecordIds = ids;
            this.genBatch = { total: res.total, done: 0, succeeded: 0, failed: 0, finished: false };
            this.toast('Batch started', `Generating ${res.total} documents in the background.`, 'success');
            this.pollGenerate();
        } catch (e) {
            this.fail(e);
            this.genRunning = false;
        }
    }

    pollGenerate() {
        clearInterval(this._genPoll);
        this._genPoll = setInterval(async () => {
            try {
                const s = await getGenerateStatus({
                    templateId: this.selectedTemplateId,
                    recordIds: this._genRecordIds,
                    startedAtIso: this._genStartedAt
                });
                this.genBatch = s;
                if (s.finished) {
                    clearInterval(this._genPoll);
                    this._genPoll = null;
                    this.genRunning = false;
                    this.loadActivity();   // the run belongs in the history now
                    this.toast(
                        'Batch finished',
                        `${s.succeeded} generated` + (s.failed ? `, ${s.failed} failed` : '.'),
                        s.failed ? 'warning' : 'success'
                    );
                }
            } catch (e) {
                // A dropped poll is not worth interrupting the user — the batch
                // is server-side and carries on regardless.
                console.warn('[SignForce] generate poll failed', e);
            }
        }, POLL_MS);
    }

    get genPercent() {
        if (!this.genBatch || !this.genBatch.total) return 0;
        return Math.round((this.genBatch.done / this.genBatch.total) * 100);
    }
    get genBarStyle() { return `width:${this.genPercent}%`; }
    get genFinished() { return !!this.genBatch && this.genBatch.finished; }
    get genHasFailures() { return !!this.genBatch && this.genBatch.failed > 0; }

    /**
     * True only when the run actually produced something.
     *
     * The closing hint tells the user where to find their documents. On a run
     * where every record failed there are no documents to find, so pointing at
     * Generated Documents sends them looking for files that were never created —
     * directly under a red list explaining that nothing could be stored.
     */
    get genProducedAnything() {
        return !!this.genBatch && (this.genBatch.succeeded || 0) > 0;
    }

    /* Anything not yet accounted for is still waiting on the queue. */
    get genQueued() {
        if (!this.genBatch) return 0;
        return Math.max(0, this.genBatch.total - this.genBatch.done);
    }
    get genHasQueued() { return this.genQueued > 0; }

    /* Captured when the run starts: the picker can be changed mid-run, and the
       progress panel must keep describing the batch that is actually going. */
    get genRunTemplate() { return this._runTemplateName || '—'; }
    get genRunObject() { return this._runObjectName || '—'; }

    get genProgressLabel() {
        if (!this.genBatch) return '';
        return `${this.genBatch.done} of ${this.genBatch.total} processed`;
    }

    /* ── recent activity ── */

    async loadActivity() {
        this.activityLoading = true;
        try {
            const rows = await getRecentActivity({ hoursBack: 168 });
            this.activity = (rows || [])
                .map((a) => ({
                    ...a,
                    key: `${a.templateId}|${a.objectApiName}`,
                    // A second stable key: LWC needs a distinct one for the
                    // detail row that follows each summary row.
                    detailKey: `${a.templateId}|${a.objectApiName}|d`,
                    failedClass: a.failed > 0 ? 'bc-num bc-bad' : 'bc-num bc-muted',
                    lastRunText: this.relativeTime(a.lastRun),
                    expanded: false,
                    detailLoading: false,
                    hasDetail: false,
                    hasVisible: false,
                    detail: [],
                    detailVisible: [],
                    detailNote: '',
                    detailSummary: '',
                    detailPage: 1,
                    showFailedOnly: false,
                    showPager: false,
                    pageLabel: '',
                    prevDisabled: true,
                    nextDisabled: true,
                    filterLabel: 'Show failed only',
                    emptyText: '',
                    caretClass: 'bc-caret',
                    // Naming the count makes it plain there is something behind
                    // the row, and how much of it there is.
                    viewLabel: this.viewLabelFor((a.succeeded || 0) + (a.failed || 0))
                }))
                .sort((x, y) => new Date(y.lastRun) - new Date(x.lastRun));
        } catch (e) {
            this.activity = [];
        } finally {
            this.activityLoading = false;
        }
    }

    get hasActivity() { return this.activity.length > 0; }

    /* ── the documents behind an activity row ──
     *
     * The table is an aggregate: "Test / Account / 43 completed" says how many
     * were produced but not which. After a bulk run from a list view there was
     * nowhere that listed them — Document_Generation_Log__c has no tab, and the
     * per-record card shows one record at a time, so seeing the result of a
     * 43-record run meant opening 43 records.
     */

    viewLabelFor(n) {
        return n === 1 ? 'View 1 document' : `View ${n} documents`;
    }

    async handleActivityRow(e) {
        const key = e.currentTarget.dataset.key;
        const row = this.activity.find((a) => a.key === key);
        if (!row) return;

        if (row.expanded) {
            this._patchActivity(key, {
                expanded: false, caretClass: 'bc-caret',
                viewLabel: this.viewLabelFor(row.detailTotal || row.succeeded + row.failed)
            });
            return;
        }

        // Already fetched once — reopen without another round trip.
        if (row.detail.length || row.hasDetail) {
            this._patchActivity(key, {
                expanded: true, caretClass: 'bc-caret bc-caret-open', viewLabel: 'Hide'
            });
            return;
        }

        this._patchActivity(key, {
            expanded: true, detailLoading: true, caretClass: 'bc-caret bc-caret-open'
        });

        try {
            const rows = await getActivityDetail({
                templateId: row.templateId,
                objectApiName: row.objectApiName,
                hoursBack: 168
            });
            // Failures first. They are the only rows anyone has to act on, and
            // with ten to a page a single failure among forty-three would
            // otherwise sit on page four where nobody would find it. sort() is
            // stable, so the server's newest-first order survives inside each
            // group.
            const detail = (rows || [])
                .map((d) => this._decorateDoc(d))
                .sort((a, b) => (b.isFailure ? 1 : 0) - (a.isFailure ? 1 : 0));

            const failed = detail.filter((d) => d.isFailure).length;
            this._patchActivity(key, {
                detailLoading: false,
                detail,
                detailFailed: failed,
                detailTotal: detail.length,
                detailSummary: failed
                    ? `${detail.length} documents · ${failed} failed`
                    : `${detail.length} documents · all succeeded`,
                detailPage: 1,
                showFailedOnly: false,
                detailNote: detail.length >= DETAIL_LIMIT
                    ? `Showing the most recent ${DETAIL_LIMIT}.`
                    : '',
                ...this._detailView({ ...row, detail, detailPage: 1, showFailedOnly: false })
            });
        } catch (err) {
            this._patchActivity(key, {
                detailLoading: false, detail: [], detailVisible: [],
                hasDetail: false, hasVisible: false
            });
            this.fail(err);
        }
    }

    /**
     * The slice of one row's documents that is on screen, plus everything the
     * pager needs to describe itself.
     *
     * It is computed and stored rather than exposed as a getter because each
     * activity row has its own page and its own filter, and a template getter
     * cannot be asked about a particular row.
     */
    _detailView(row) {
        const all = row.showFailedOnly ? row.detail.filter((d) => d.isFailure) : row.detail;
        const pages = Math.max(1, Math.ceil(all.length / DETAIL_PAGE));
        // Clamped: switching the filter on can leave the page number past the
        // end of the shorter list.
        const page = Math.min(Math.max(1, row.detailPage || 1), pages);
        const from = (page - 1) * DETAIL_PAGE;
        const slice = all.slice(from, from + DETAIL_PAGE);

        return {
            detailPage: page,
            detailVisible: slice,
            hasDetail: row.detail.length > 0,
            hasVisible: slice.length > 0,
            showPager: all.length > DETAIL_PAGE,
            pageLabel: all.length
                ? `${from + 1}–${from + slice.length} of ${all.length}`
                : '0 of 0',
            prevDisabled: page <= 1,
            nextDisabled: page >= pages,
            emptyText: row.showFailedOnly
                ? 'Nothing failed here.'
                : 'No documents recorded for this template in the last 7 days.'
        };
    }

    _stepDetail(key, delta) {
        const row = this.activity.find((a) => a.key === key);
        if (!row) return;
        const next = { ...row, detailPage: (row.detailPage || 1) + delta };
        this._patchActivity(key, this._detailView(next));
    }

    handleDetailPrev(e) { this._stepDetail(e.currentTarget.dataset.key, -1); }
    handleDetailNext(e) { this._stepDetail(e.currentTarget.dataset.key, 1); }

    handleDetailFilter(e) {
        const key = e.currentTarget.dataset.key;
        const row = this.activity.find((a) => a.key === key);
        if (!row) return;
        // Back to page one: page three of "everything" means nothing once the
        // list is cut down to the failures.
        const next = { ...row, showFailedOnly: !row.showFailedOnly, detailPage: 1 };
        this._patchActivity(key, {
            showFailedOnly: next.showFailedOnly,
            filterLabel: next.showFailedOnly ? 'Show all' : 'Show failed only',
            ...this._detailView(next)
        });
    }

    _decorateDoc(d) {
        const ok = d.status === 'Success';
        return {
            logId: d.logId,
            isFailure: !ok,
            recordName: d.recordName,
            // A failed attempt has no output file, so there is nothing to name.
            filename: ok ? (d.filename || 'Document') : 'Not created',
            whenText: this.relativeTime(d.createdAt),
            // The record always resolves; the file does not. Output_File_Id__c
            // is deliberately null for auto-create templates, where the document
            // is attached to the Agreement rather than to the record — so the
            // record link is the one that is always worth offering, and it lands
            // on the Generated Documents card where every action lives anyway.
            hasRecord: !!d.recordId,
            recordUrl: d.recordId ? `/lightning/r/${d.recordId}/view` : '',
            hasLink: ok && !!d.fileId,
            fileUrl: d.fileId ? `/lightning/r/ContentDocument/${d.fileId}/view` : '',
            // Error_Message__c is a type name, a message and a stack trace, so
            // the row carries the explanation instead of the raw text.
            reason: ok ? '' : friendlyError(d.error).text,
            rowClass: ok ? 'bc-doc' : 'bc-doc bc-doc-bad',
            dotClass: ok ? 'bc-doc-dot bc-doc-dot-ok' : 'bc-doc-dot bc-doc-dot-bad'
        };
    }

    /* Replaces the one row rather than mutating it: @track only reacts to a new
       array here, and mutating in place left the caret and the panel stale. */
    _patchActivity(key, patch) {
        this.activity = this.activity.map((a) => (a.key === key ? { ...a, ...patch } : a));
    }

    relativeTime(iso) {
        if (!iso) return '';
        const ms = Date.now() - new Date(iso).getTime();
        if (isNaN(ms)) return '';
        const min = Math.round(ms / 60000);
        if (min < 1) return 'Just now';
        if (min < 60) return min === 1 ? '1 minute ago' : `${min} minutes ago`;
        const hr = Math.round(min / 60);
        if (hr < 24) return hr === 1 ? '1 hour ago' : `${hr} hours ago`;
        const day = Math.round(hr / 24);
        return day === 1 ? 'Yesterday' : `${day} days ago`;
    }

    /* ══════════════ SEND ══════════════ */

    async loadAgreements() {
        try {
            const rows = await listMasterAgreements();
            this.agreements = rows || [];
        } catch (e) {
            this.fail(e);
        }
    }

    get agreementOptions() {
        return this.agreements.map((a) => ({
            label: a.status ? `${a.name} — ${a.status}` : a.name,
            value: a.id
        }));
    }

    handleAgreementChange(e) {
        this.selectedAgreementId = e.detail.value;
        this.sendBatch = null;
    }

    /* ---------------------------------------------------------------
     * Recipients
     *
     * One row per person, name and email in their own field. The earlier
     * version was a single textarea parsed with a regex, and a line that
     * failed to parse was silently dropped — the count just said "0 valid
     * recipients" with no way to tell which line was at fault. Here every
     * problem is attached to the row that has it.
     * --------------------------------------------------------------- */

    _rowSeq = 0;

    newRow(name, email) {
        this._rowSeq += 1;
        return { key: `r${this._rowSeq}`, name: name || '', email: email || '' };
    }

    /** Rows plus their computed validation state, for the template. */
    get rows() {
        const seen = new Set();
        return this._rows.map((r) => {
            const name = (r.name || '').trim();
            const email = (r.email || '').trim();
            let error = '';

            if (email) {
                if (!EMAIL_RE.test(email)) {
                    error = 'This is not a valid email address.';
                } else if (seen.has(email.toLowerCase())) {
                    // Two copies of one agreement to one inbox is never intended.
                    error = 'This email is already in the list below or above.';
                } else {
                    seen.add(email.toLowerCase());
                }
            } else if (name) {
                error = 'Email is required.';
            }

            return {
                ...r,
                error,
                rowClass: error ? 'bc-row bc-row-bad' : 'bc-row',
                emailClass: error ? 'bc-in bc-in-bad' : 'bc-in'
            };
        });
    }

    /** The rows that will actually be sent. Blank rows are simply skipped. */
    get validRecipients() {
        return this.rows
            .filter((r) => !r.error && (r.email || '').trim())
            .map((r) => ({
                name: (r.name || '').trim() || (r.email || '').trim(),
                email: (r.email || '').trim()
            }));
    }

    get problemCount() { return this.rows.filter((r) => r.error).length; }
    get recipientCount() { return this.validRecipients.length; }

    get recipientCountLabel() {
        const n = this.recipientCount;
        return n === 1 ? '1 ready to send' : `${n} ready to send`;
    }

    /** Says why the button is off, instead of leaving a dead grey button. */
    get sendReadyLabel() {
        if (!this.selectedAgreementId) return 'Pick an agreement in Step 1 first.';
        if (this.problemCount) {
            return this.problemCount === 1
                ? '1 row needs fixing before you can send.'
                : `${this.problemCount} rows need fixing before you can send.`;
        }
        if (!this.recipientCount) return 'Add at least one recipient.';
        return '';
    }

    get hasDupes() { return this.rows.some((r) => r.error.startsWith('This email is already')); }
    get dupeMessage() {
        return 'The same email appears more than once. Remove the extra rows — one person cannot be sent two copies of the same agreement.';
    }

    get sendDisabled() {
        return this.sendRunning || !this.selectedAgreementId
            || this.recipientCount === 0 || this.problemCount > 0;
    }

    /**
     * Bound to onchange, not oninput, on purpose: the row is re-checked when
     * the field is left, so a half-typed address is not flagged red while it
     * is still being typed, and the re-render cannot move the caret mid-word.
     */
    handleRowChange(e) {
        const { key, field } = e.target.dataset;
        const value = e.target.value;
        this._rows = this._rows.map((r) => (r.key === key ? { ...r, [field]: value } : r));
    }

    handleAddRow() {
        this._rows = [...this._rows, this.newRow()];
    }

    handleRemoveRow(e) {
        const key = e.currentTarget.dataset.key;
        const left = this._rows.filter((r) => r.key !== key);
        // Never leave the panel with nothing to type into.
        this._rows = left.length ? left : [this.newRow()];
    }

    /* ---- bulk paste ------------------------------------------------- */

    togglePaste() {
        this.showPaste = !this.showPaste;
        if (!this.showPaste) this.pasteRaw = '';
    }

    handlePasteChange(e) { this.pasteRaw = e.target.value; }

    get pasteToggleLabel() { return this.showPaste ? 'Close paste box' : 'Paste a list instead'; }

    get pasteLines() {
        const out = [];
        (this.pasteRaw || '').split(/\r?\n/).forEach((line) => {
            const text = line.trim();
            if (!text) return;
            let name = '';
            let email = text;
            // Split on the LAST separator: names can contain commas
            // ("Cooper, Jane"), an email address never does.
            const cut = Math.max(text.lastIndexOf(','), text.lastIndexOf('\t'), text.lastIndexOf(';'));
            if (cut > -1) {
                name = text.slice(0, cut).trim();
                email = text.slice(cut + 1).trim();
            }
            out.push(this.cleanPair(name, email));
        });
        return out;
    }

    get pasteCount() { return this.pasteLines.length; }

    /**
     * Pasted lines become rows — including the broken ones, which then show
     * their own error. Dropping them here is what made the old textarea
     * confusing: the address vanished and the count silently went down.
     */
    handleApplyPaste() {
        const incoming = this.pasteLines;
        if (!incoming.length) return;
        this.appendRows(incoming);
        this.pasteRaw = '';
        this.showPaste = false;
        this.toast('Added', `${incoming.length} row(s) added. Check for any marked in red.`, 'success');
    }

    /** Shared by paste and CSV import. Empty starter rows make way. */
    appendRows(list) {
        const blank = (r) => !(r.name || '').trim() && !(r.email || '').trim();
        this._rows = [
            ...this._rows.filter((r) => !blank(r)),
            ...list.map((p) => this.newRow(p.name, p.email))
        ];
    }

    /* ---- CSV --------------------------------------------------------
     * Download a sample, fill it in, upload it back. The sample exists so
     * nobody has to guess the column names, and the import reads columns by
     * their heading rather than their position, so a file with extra columns
     * or a different order still works.
     * ----------------------------------------------------------------- */

    /**
     * The sample as a data URI, handed straight to an <a download> in the
     * template. The usual createElement/appendChild/click dance needs
     * document.body, which Lightning Web Security will not hand to a component
     * outside its own shadow root — it threw "Script error. null" from
     * aura_prod.js. No DOM is touched this way.
     *
     * The BOM is deliberate: without it Excel reads a UTF-8 CSV in the local
     * codepage and mangles any non-ASCII name.
     */
    get sampleCsvHref() {
        return 'data:text/csv;charset=utf-8,' + encodeURIComponent(BOM + SAMPLE_CSV);
    }

    handleCsvFile(e) {
        const input = e.target;
        const file = input.files && input.files[0];
        // Clear it now: picking the SAME file twice fires no change event
        // otherwise, so a corrected re-upload would look like a dead button.
        input.value = '';
        if (!file) return;

        if (file.size > MAX_CSV_BYTES) {
            this.toast('File too large', 'Keep the CSV under 1 MB. Split a bigger list into batches.', 'error');
            return;
        }

        const reader = new FileReader();
        reader.onerror = () => {
            this.toast('Could not read the file', 'Open it in Excel or Sheets and save again as CSV.', 'error');
        };
        reader.onload = () => {
            let list;
            try {
                list = this.csvToRecipients(String(reader.result || ''));
            } catch (err) {
                this.toast('Could not read the file', 'It does not look like a CSV. Download the sample and use that layout.', 'error');
                return;
            }
            if (!list.length) {
                this.toast('Nothing to import', 'No rows found. The file needs a Name column and an Email column.', 'warning');
                return;
            }
            let note = '';
            if (list.length > MAX_CSV_ROWS) {
                list = list.slice(0, MAX_CSV_ROWS);
                note = ` Only the first ${MAX_CSV_ROWS} were taken — send the rest as a second batch.`;
            }
            this.appendRows(list);
            this.showPaste = false;
            this.toast('Imported', `${list.length} row(s) added from ${file.name}.${note} Anything marked in red needs a look.`, 'success');
        };
        reader.readAsText(file);
    }

    /**
     * RFC 4180 reader. Quoted fields keep their commas and line breaks, and ""
     * inside a quoted field is a literal quote — a naive split(',') turns
     * "Cooper, Jane" into two broken columns, which is exactly the kind of
     * silent corruption this screen is meant to stop.
     */
    parseCsv(text) {
        const s = text.replace(/^\uFEFF/, '');   // Excel's byte-order mark
        const delim = this.sniffDelimiter(s);
        const grid = [];
        let row = [];
        let field = '';
        let quoted = false;

        for (let i = 0; i < s.length; i++) {
            const c = s[i];
            if (quoted) {
                if (c === '"') {
                    if (s[i + 1] === '"') { field += '"'; i++; }
                    else quoted = false;
                } else {
                    field += c;
                }
            } else if (c === '"') {
                quoted = true;
            } else if (c === delim) {
                row.push(field); field = '';
            } else if (c === '\n') {
                row.push(field); field = '';
                grid.push(row); row = [];
            } else if (c !== '\r') {
                field += c;
            }
        }
        if (field !== '' || row.length) { row.push(field); grid.push(row); }

        return grid.filter((r) => r.some((cell) => cell.trim() !== ''));
    }

    /** Excel in a European locale writes semicolons, and exports often use tabs. */
    sniffDelimiter(s) {
        const head = s.split(/\r?\n/).slice(0, 5).join('\n');
        const counts = { ',': 0, ';': 0, '\t': 0 };
        let quoted = false;
        for (const ch of head) {
            if (ch === '"') quoted = !quoted;
            else if (!quoted && ch in counts) counts[ch] += 1;
        }
        const best = Object.keys(counts).sort((a, b) => counts[b] - counts[a])[0];
        return counts[best] ? best : ',';
    }

    csvToRecipients(text) {
        const grid = this.parseCsv(text);
        if (!grid.length) return [];

        const head = grid[0].map((c) => c.trim());
        // A header row is one with no address anywhere in it. Files without a
        // header still import — the first line is simply treated as data.
        const hasHeader = !head.some((c) => c.includes('@'));

        let emailCol = -1, nameCol = -1, firstCol = -1, lastCol = -1;
        if (hasHeader) {
            head.forEach((h, i) => {
                const k = h.toLowerCase().replace(/[\s_-]/g, '');
                if (emailCol < 0 && (k.includes('email') || k === 'mail')) emailCol = i;
                if (firstCol < 0 && (k === 'firstname' || k === 'givenname')) firstCol = i;
                if (lastCol < 0 && (k === 'lastname' || k === 'surname' || k === 'familyname')) lastCol = i;
                if (nameCol < 0 && (k === 'name' || k === 'fullname'
                    || k === 'recipientname' || k === 'signername')) nameCol = i;
            });
        }

        const out = [];
        for (let i = hasHeader ? 1 : 0; i < grid.length; i++) {
            const cells = grid[i].map((c) => c.trim());
            if (!cells.some((c) => c)) continue;

            let email = emailCol > -1 ? (cells[emailCol] || '') : '';
            if (!email) {
                // No usable heading: the cell holding an "@" is the address,
                // wherever the export happened to put it.
                const at = cells.findIndex((c) => c.includes('@'));
                if (at > -1) email = cells[at];
            }

            let name = '';
            if (firstCol > -1 || lastCol > -1) {
                name = `${cells[firstCol] || ''} ${cells[lastCol] || ''}`.trim();
            }
            if (!name && nameCol > -1) name = cells[nameCol] || '';
            if (!name) name = cells.find((c) => c && c !== email && !c.includes('@')) || '';

            // Bad rows are imported too, so the row itself can say what is wrong.
            out.push(this.cleanPair(name, email));
        }
        return out;
    }

    /**
     * Tidies one pair before it becomes a row.
     *
     * Outlook and most mail clients copy an address as "Jane Cooper
     * <jane@acme.com>", and a quoted CSV field can carry a hard line break, so
     * neither is safe to drop straight into an input.
     */
    cleanPair(name, email) {
        let n = (name || '').replace(/\s+/g, ' ').trim();
        let e = (email || '').trim();

        const angled = e.match(/^(.*?)<([^>]+)>\s*$/);
        if (angled) {
            if (!n) n = angled[1].replace(/\s+/g, ' ').trim();
            e = angled[2];
        }

        e = e.replace(/\s+/g, '').replace(/^["']+|["',;]+$/g, '');
        n = n.replace(/^["']+|["']+$/g, '').trim();
        return { name: n, email: e };
    }

    async handleStartSend() {
        const list = this.validRecipients;
        if (!list.length) return;

        this.sendRunning = true;
        this.sendBatch = null;
        try {
            const res = await startBulkSend({
                sourceAgreementId: this.selectedAgreementId,
                recipientsJson: JSON.stringify(list)
            });
            this._sendBatchId = res.batchId;
            this.sendBatch = { total: res.total, sent: 0, completed: 0, declined: 0, draft: 0 };
            this.toast('Batch started', `Sending to ${res.total} recipients in the background.`, 'success');
            this.pollSend();
        } catch (e) {
            this.fail(e);
            this.sendRunning = false;
        }
    }

    pollSend() {
        clearInterval(this._sendPoll);
        this._sendPoll = setInterval(async () => {
            try {
                const s = await getBulkStatus({
                    sourceAgreementId: this.selectedAgreementId,
                    batchId: this._sendBatchId
                });
                this.sendBatch = s;
                const handled = (s.sent || 0) + (s.completed || 0) + (s.declined || 0);
                if (s.total && handled >= s.total) {
                    clearInterval(this._sendPoll);
                    this._sendPoll = null;
                    this.sendRunning = false;
                    this.toast('Batch finished', `${s.total} agreements created and sent.`, 'success');
                }
            } catch (e) {
                console.warn('[SignForce] send poll failed', e);
            }
        }, POLL_MS);
    }

    get sendPercent() {
        if (!this.sendBatch || !this.sendBatch.total) return 0;
        const handled = (this.sendBatch.sent || 0) + (this.sendBatch.completed || 0)
            + (this.sendBatch.declined || 0);
        return Math.round((handled / this.sendBatch.total) * 100);
    }
    get sendBarStyle() { return `width:${this.sendPercent}%`; }
    get sendHasCompleted() { return !!this.sendBatch && this.sendBatch.completed > 0; }
    get sendHasDeclined() { return !!this.sendBatch && this.sendBatch.declined > 0; }
    get sendProgressLabel() {
        if (!this.sendBatch) return '';
        const handled = (this.sendBatch.sent || 0) + (this.sendBatch.completed || 0)
            + (this.sendBatch.declined || 0);
        return `${handled} of ${this.sendBatch.total} created`;
    }

    /* ── failures ──
     *
     * Anything that goes wrong lands here instead of in a toast. A toast is
     * fine for "batch started"; it is the wrong container for a failure,
     * because it is gone before the reader has finished the sentence and the
     * screen then looks exactly as it did before. `fault` stays put.
     */
    fail(e) {
        this.fault = friendlyError(e);
        this.showFaultDetail = false;
    }

    get hasFault() { return !!this.fault; }
    dismissFault() { this.fault = null; }
    toggleFaultDetail() { this.showFaultDetail = !this.showFaultDetail; }
    get faultDetailLabel() {
        return this.showFaultDetail ? 'Hide technical details' : 'Show technical details';
    }

    /* ── which records failed ── */

    get genFailureRows() {
        const rows = (this.genBatch && this.genBatch.rows) || [];
        return rows
            .filter((r) => r.status === 'Failure')
            .slice(0, FAIL_LIMIT)
            .map((r) => ({
                recordId: r.recordId,
                name: this._genNameFor(r.recordId),
                // Error_Message__c holds "<TypeName>: <message>" plus a stack
                // trace, so the row carries the explanation, not the raw text.
                reason: friendlyError(r.error).text
            }));
    }

    get genShowFailures() { return this.genFailureRows.length > 0; }

    get genFailureHeading() {
        const n = (this.genBatch && this.genBatch.failed) || 0;
        return n === 1 ? 'This record could not be done:' : `These ${n} records could not be done:`;
    }

    get genFailureNote() {
        const n = (this.genBatch && this.genBatch.failed) || 0;
        return n > FAIL_LIMIT
            ? `Showing the first ${FAIL_LIMIT} of ${n}. The rest are on the Document Generation Log.`
            : '';
    }

    _genNameFor(recordId) {
        const hit = this.records.find((r) => r.id === recordId);
        return (hit && hit.name) || recordId;
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
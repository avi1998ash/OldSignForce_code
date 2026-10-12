import { LightningElement, api, track } from 'lwc';
import getTemplateLayout from '@salesforce/apex/TemplateService.getTemplateLayout';
import getRecordEmailFields from '@salesforce/apex/TemplateService.getRecordEmailFields';

const MANUAL_OPTION_VALUE = '__MANUAL__';

/**
 * templateSignerMapper — the "Map signer emails" step, as a reusable control.
 *
 * A template can define signers, and can leave fields without one. Both have to
 * be resolved to a real email address before an agreement is created, otherwise
 * the agreement arrives with no recipients or with fields nobody can complete.
 *
 * This lives on its own because two different routes create agreements from a
 * template — generating a document, and raising one from the generated-documents
 * panel — and the mapping rules are subtle enough (unassigned fields may share a
 * signer, defined signers may not share an email) that a second copy would drift.
 *
 * Usage:
 *   <c-template-signer-mapper template-id={id} record-id={rec} onready={h}>
 *   The `ready` event reports {hasRows}; a caller can skip its dialog entirely
 *   when there is nothing to map. Then call validate() and buildMapping().
 */
export default class TemplateSignerMapper extends LightningElement {
    @track signerMapping = [];
    @track recordEmailOptions = [];
    @track isLoading = false;

    _templateId;
    _recordId;
    _loadToken = 0;

    @api
    get templateId() { return this._templateId; }
    set templateId(value) {
        this._templateId = value;
        this._load();
    }

    @api
    get recordId() { return this._recordId; }
    set recordId(value) {
        this._recordId = value;
        this._load();
    }

    /** True when there is anything for the user to map. */
    @api get hasRows() {
        return (this.signerMapping || []).length > 0;
    }

    /**
     * The mapping in the shape materializeSignersAndFieldsMapped expects:
     *   { signers: { <key>: { name, email } }, fieldEmails: { <index>: email } }
     */
    @api buildMapping() {
        const signers = {};
        const fieldEmails = {};
        (this.signerMapping || []).forEach((row) => {
            if (!row) return;
            if (row.kind === 'field') {
                if (row.idx === undefined || row.idx === null) return;
                fieldEmails[String(row.idx)] = row.email;
                return;
            }
            if (!row.key) return;
            signers[row.key] = { name: row.name, email: row.email };
        });
        return { signers, fieldEmails };
    }

    /**
     * Checks every row carries a usable email. Returns null when valid, or a
     * message for the caller to surface — the caller owns the toast so this
     * control stays usable inside a dialog or a page alike.
     */
    @api validate() {
        const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        const invalid = (this.signerMapping || []).filter((row) => {
            const email = (row && row.email ? String(row.email) : '').trim();
            return !emailRe.test(email);
        });
        if (invalid.length > 0) {
            const who = invalid
                .map((r) => (r.kind === 'field'
                    ? (r.label || 'an unassigned field')
                    : (r.name || r.role || 'a signer')))
                .join(', ');
            return 'Enter a valid email for: ' + who + '.';
        }

        // Two signer slots sharing an email are ambiguous. UNASSIGNED FIELD rows
        // are exempt on purpose: several fields legitimately point at the same
        // signer, and Apex collapses a shared email onto that one recipient.
        const seen = new Set();
        for (const row of this.signerMapping || []) {
            if (!row || row.kind === 'field') continue;
            const email = (row.email ? String(row.email) : '').trim().toLowerCase();
            if (!email) continue;
            if (seen.has(email)) {
                return `The email "${row.email}" is assigned to more than one signer. `
                    + 'Give each signer a unique email.';
            }
            seen.add(email);
        }
        return null;
    }

    async _load() {
        if (!this._templateId) {
            this.signerMapping = [];
            this.recordEmailOptions = [];
            return;
        }
        const token = ++this._loadToken;
        this.isLoading = true;
        try {
            const layoutJson = await getTemplateLayout({ templateId: this._templateId });
            if (token !== this._loadToken) return;   // a newer load superseded this one

            let layout = null;
            try { layout = layoutJson ? JSON.parse(layoutJson) : null; } catch (e) { layout = null; }
            const signers = (layout && Array.isArray(layout.signers)) ? layout.signers : [];
            const fields = (layout && Array.isArray(layout.fields)) ? layout.fields : [];

            // A field is UNASSIGNED when its signerKey is blank or names a signer
            // the template does not define — those need their own mapping row.
            const signerKeys = new Set(
                signers.map((s) => (s && s.key != null) ? String(s.key) : '').filter((k) => k !== '')
            );
            const unassignedIdx = [];
            fields.forEach((f, idx) => {
                const sk = (f && f.signerKey != null) ? String(f.signerKey).trim() : '';
                if (sk === '' || !signerKeys.has(sk)) unassignedIdx.push(idx);
            });

            if (signers.length === 0 && unassignedIdx.length === 0) {
                this.signerMapping = [];
                this.recordEmailOptions = [];
                this._announce();
                return;
            }

            // The open record's Email-type values, offered as pick-list choices.
            let emailFields = [];
            if (this._recordId) {
                try {
                    emailFields = await getRecordEmailFields({ recordId: this._recordId });
                } catch (e) {
                    emailFields = [];   // manual entry only
                }
            }
            if (token !== this._loadToken) return;

            const recordEmails = [];
            const options = [];
            (emailFields || []).forEach((f) => {
                if (!f) return;
                const value = (f.value || '').trim();
                if (!value) return;
                options.push({ label: (f.label || 'Email') + ' - ' + value, value });
                recordEmails.push(value);
            });
            options.push({ label: 'Type manually…', value: MANUAL_OPTION_VALUE });
            const firstRecordEmail = recordEmails.length ? recordEmails[0] : null;

            const signerRows = signers.map((s) => {
                // Keep the email the admin set on the template. Only fall back to a
                // record email when the template deliberately left it blank.
                const stored = (s && s.email) ? String(s.email).trim() : '';
                const email = stored || firstRecordEmail || '';
                return {
                    kind: 'signer',
                    key: (s && s.key) ? s.key : '',
                    name: (s && s.name) ? s.name : '',
                    role: (s && s.role) ? s.role : 'Signer',
                    order: (s && s.order != null) ? s.order : null,
                    email,
                    useManual: recordEmails.length === 0 || !recordEmails.includes(email)
                };
            });

            const firstSignerEmail =
                (signerRows.find((s) => s.email && s.email.trim()) || {}).email || '';
            const fieldRows = unassignedIdx.map((idx) => {
                const f = fields[idx] || {};
                const email = firstSignerEmail || firstRecordEmail || '';
                return {
                    kind: 'field',
                    idx,
                    label: (f.type ? String(f.type) : 'Field')
                        + ' (page ' + (f.page != null ? f.page : 1) + ')',
                    email,
                    useManual: recordEmails.length === 0 || !recordEmails.includes(email)
                };
            });

            this.recordEmailOptions = options;
            this.signerMapping = signerRows.concat(fieldRows);
        } catch (e) {
            this.signerMapping = [];
            this.recordEmailOptions = [];
        } finally {
            if (token === this._loadToken) {
                this.isLoading = false;
                this._announce();
            }
        }
    }

    /** Lets a caller skip its dialog when there is nothing to map. */
    _announce() {
        this.dispatchEvent(new CustomEvent('ready', {
            detail: { hasRows: this.hasRows }
        }));
    }

    /* ── rows for the template ─────────────────────────────────────── */

    get signerRows() {
        return (this.signerMapping || [])
            .filter((r) => r && r.kind === 'signer')
            .map((r) => {
                const hasOrder = r.order !== null && r.order !== undefined && r.order !== '';
                const nameTrim = (r.name && String(r.name).trim()) || '';
                // Never show a blank, anonymous row.
                const displayName = nameTrim || (hasOrder ? ('Signer ' + r.order) : 'Signer');
                return { ...r, displayName, orderLabel: hasOrder ? ('Order ' + r.order) : '' };
            });
    }

    get fieldRows() {
        return (this.signerMapping || []).filter((r) => r && r.kind === 'field');
    }

    /** Defined signers that already have an email. The value is that email, which
     *  Apex resolves back to the same recipient — so several fields can share one
     *  signer without creating duplicates. */
    get signerPickerOptions() {
        return this.signerRows
            .filter((s) => s.email && String(s.email).trim())
            .map((s) => ({
                label: s.displayName + (s.orderLabel ? ' · ' + s.orderLabel : ''),
                value: String(s.email).trim()
            }));
    }

    get hasSignerPickerOptions() { return this.signerPickerOptions.length > 0; }
    get hasUnassignedFields() { return this.fieldRows.length > 0; }

    /** Only worth showing the dropdown when the record actually exposes emails. */
    get hasRecordEmails() {
        return (this.recordEmailOptions || []).some((o) => o && o.value !== MANUAL_OPTION_VALUE);
    }

    /* ── row edits ─────────────────────────────────────────────────── */

    /** Signer rows carry data-key; unassigned-field rows carry data-idx. */
    _rowMatcher(target) {
        const ds = (target && target.dataset) || {};
        if (ds.key !== undefined && ds.key !== null && ds.key !== '') {
            return (row) => row.kind === 'signer' && row.key === ds.key;
        }
        return (row) => row.kind === 'field' && String(row.idx) === String(ds.idx);
    }

    handleEmailChange(e) {
        const matches = this._rowMatcher(e.target);
        const value = e.detail.value;
        this.signerMapping = this.signerMapping.map((row) => {
            if (!matches(row)) return row;
            return (value === MANUAL_OPTION_VALUE)
                ? { ...row, useManual: true }
                : { ...row, email: value, useManual: false };
        });
    }

    handleManualChange(e) {
        const matches = this._rowMatcher(e.target);
        const value = e.target.value;
        this.signerMapping = this.signerMapping.map(
            (row) => (matches(row) ? { ...row, email: value } : row)
        );
    }
}
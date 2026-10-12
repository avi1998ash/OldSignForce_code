import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getLicencePage from '@salesforce/apex/SignForceLicenceController.getLicencePage';
import assignLicences from '@salesforce/apex/SignForceLicenceController.assignLicences';
import revokeLicences from '@salesforce/apex/SignForceLicenceController.revokeLicences';

const UNLIMITED = -1;

export default class SignforceLicences extends LightningElement {
    @track summary = {};
    @track users = [];
    @track selectedIds = [];
    @track search = '';
    @track filter = 'all';
    @track loading = true;
    @track working = false;
    @track errorMsg = '';

    connectedCallback() {
        this.load();
    }

    async load() {
        this.loading = true;
        this.errorMsg = '';
        try {
            const page = await getLicencePage();
            this.summary = page.summary || {};
            this.users = (page.users || []).map((u) => ({ ...u }));
            // Drop selections for rows that no longer exist, so a stale tick can
            // never be submitted after a refresh.
            const live = new Set(this.users.map((u) => u.userId));
            this.selectedIds = this.selectedIds.filter((id) => live.has(id));
        } catch (e) {
            this.errorMsg = this.msgOf(e);
        } finally {
            this.loading = false;
        }
    }

    /* ── seat counters ────────────────────────────────────────────── */

    get unlimited() { return this.summary.unlimited === true; }
    get notManaged() { return this.summary.licenceManaged === false; }

    get allowedLabel() {
        if (this.notManaged) return '—';
        return this.unlimited ? 'Unlimited' : String(this.summary.allowed ?? 0);
    }
    get remainingLabel() {
        if (this.notManaged) return '—';
        return this.unlimited ? 'Unlimited' : String(this.summary.remaining ?? 0);
    }
    get usedLabel() { return this.notManaged ? '—' : String(this.summary.used ?? 0); }

    get barStyle() {
        const pct = this.unlimited ? 0 : Math.min(100, this.summary.percentUsed || 0);
        return `width:${pct}%`;
    }
    get barClass() {
        const pct = this.summary.percentUsed || 0;
        let tone = 'ok';
        if (pct >= 100) tone = 'full';
        else if (pct >= 80) tone = 'warn';
        return `sfl-bar-fill sfl-${tone}`;
    }
    get showBar() { return !this.notManaged && !this.unlimited; }

    get seatWarning() {
        if (this.notManaged || this.unlimited) return '';
        const left = this.summary.remaining ?? 0;
        if (left === 0) return 'Every seat is in use. Free one before assigning another.';
        if (left <= 2) return `Only ${left} seat${left === 1 ? '' : 's'} left.`;
        return '';
    }
    get hasSeatWarning() { return this.seatWarning !== ''; }

    get expiryLabel() {
        if (!this.summary.expirationDate) return null;
        return new Date(this.summary.expirationDate).toLocaleDateString(undefined, {
            day: '2-digit', month: 'short', year: 'numeric'
        });
    }
    get expiringSoon() { return this.summary.expiringSoon === true; }

    /* ── roster ───────────────────────────────────────────────────── */

    get filteredUsers() {
        const q = this.search.trim().toLowerCase();
        const sel = new Set(this.selectedIds);
        return this.users
            .filter((u) => {
                if (this.filter === 'licensed' && !u.hasLicence) return false;
                if (this.filter === 'unlicensed' && u.hasLicence) return false;
                if (this.filter === 'incomplete' && u.ready) return false;
                if (!q) return true;
                return (u.name || '').toLowerCase().includes(q)
                    || (u.username || '').toLowerCase().includes(q)
                    || (u.email || '').toLowerCase().includes(q);
            })
            .map((u) => ({
                ...u,
                selected: sel.has(u.userId),
                rowClass: sel.has(u.userId) ? 'sfl-row sfl-row-sel' : 'sfl-row',
                stateClass: u.ready
                    ? 'sfl-pill sfl-pill-ok'
                    : (u.hasLicence || u.hasPermSet ? 'sfl-pill sfl-pill-warn' : 'sfl-pill sfl-pill-off')
            }));
    }

    get filterOptions() {
        return [
            { label: 'All users', value: 'all' },
            { label: 'With a seat', value: 'licensed' },
            { label: 'Without a seat', value: 'unlicensed' },
            { label: 'Incomplete access', value: 'incomplete' }
        ];
    }

    get selectedCount() { return this.selectedIds.length; }
    get hasSelection() { return this.selectedIds.length > 0; }
    get noResults() { return !this.loading && this.filteredUsers.length === 0; }
    get busy() { return this.loading || this.working; }

    get assignLabel() {
        return this.selectedCount ? `Assign seat (${this.selectedCount})` : 'Assign seat';
    }
    get revokeLabel() {
        return this.selectedCount ? `Remove seat (${this.selectedCount})` : 'Remove seat';
    }

    /* ── events ───────────────────────────────────────────────────── */

    handleSearch(e) { this.search = e.target.value; }
    handleFilter(e) { this.filter = e.detail.value; }

    handleRowToggle(e) {
        const id = e.target.dataset.id;
        const on = e.target.checked;
        const set = new Set(this.selectedIds);
        if (on) set.add(id); else set.delete(id);
        this.selectedIds = [...set];
    }

    handleSelectAllVisible(e) {
        const visible = this.filteredUsers.map((u) => u.userId);
        const set = new Set(this.selectedIds);
        if (e.target.checked) visible.forEach((id) => set.add(id));
        else visible.forEach((id) => set.delete(id));
        this.selectedIds = [...set];
    }

    handleClear() { this.selectedIds = []; }

    async handleAssign() { await this.run(assignLicences, 'assigned'); }
    async handleRevoke() { await this.run(revokeLicences, 'removed'); }

    async run(apexFn, verb) {
        if (!this.selectedIds.length || this.working) return;
        this.working = true;
        this.errorMsg = '';
        try {
            const res = await apexFn({ userIds: this.selectedIds });
            const failures = res.failures || [];
            if (res.succeeded) {
                this.toast(
                    'Done',
                    `${res.succeeded} seat${res.succeeded === 1 ? '' : 's'} ${verb}.`,
                    'success'
                );
            }
            if (failures.length) {
                // Show the real reason rather than a generic count - these are
                // usually "user has no Salesforce licence" and need a person to act.
                this.errorMsg = `${failures.length} could not be ${verb}: ${failures.join(' | ')}`;
            }
            if (!res.succeeded && !failures.length) {
                this.toast('Nothing to do', `Those users already match that state.`, 'info');
            }
            this.selectedIds = [];
            await this.load();
        } catch (e) {
            this.errorMsg = this.msgOf(e);
        } finally {
            this.working = false;
        }
    }

    handleRefresh() { this.load(); }

    /* ── helpers ──────────────────────────────────────────────────── */

    msgOf(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
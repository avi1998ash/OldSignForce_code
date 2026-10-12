import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import getDashboardData from '@salesforce/apex/DashboardController.getDashboardData';
import { stripNs } from 'c/nsUtils';

export default class SigningDashboard extends NavigationMixin(LightningElement) {

    @track isLoading = true;
    @track totalAgreements = 0;
    @track draftCount = 0;
    @track sentCount = 0;
    @track signedCount = 0;
    @track completedCount = 0;
    @track declinedCount = 0;
    @track voidedCount = 0;
    @track expiredCount = 0;
    @track pendingSigners = 0;
    @track completionRate = 0;
    @track avgCompletionHours = 0;
    @track statusBars = [];
    @track monthlyTrend = [];
    @track agreements = [];
    @track activeTab = 'all';
    @track currentPage = 1;
    pageSize = 10;

    wiredResult;

    @wire(getDashboardData)
    wired(result) {
        this.wiredResult = result;
        if (result.data) {
            this.processData(stripNs(result.data));
            this.isLoading = false;
        } else if (result.error) {
            this.isLoading = false;
        }
    }

    processData(data) {
        this.totalAgreements    = data.totalAgreements    || 0;
        this.draftCount         = data.draftCount         || 0;
        this.sentCount          = data.sentCount          || 0;
        this.signedCount        = data.signedCount        || 0;
        this.completedCount     = data.completedCount     || 0;
        this.declinedCount      = data.declinedCount      || 0;
        this.voidedCount        = data.voidedCount        || 0;
        this.expiredCount       = data.expiredCount       || 0;
        this.pendingSigners     = data.pendingSigners     || 0;
        this.completionRate     = data.completionRate     || 0;
        this.avgCompletionHours = data.avgCompletionHours || 0;

        // Status breakdown bars
        // Theme-aligned status colors (indigo primary, purple secondary).
        const statusColors = {
            'Draft':     '#94a3b8',
            'Sent':      '#6366f1',
            'Pending':   '#f59e0b',
            'Signed':    '#a855f7',
            'Completed': '#10b981',
            'Declined':  '#ef4444',
            'Voided':    '#78716c'
        };
        const counts = data.statusCounts || {};
        const total  = this.totalAgreements || 1;
        this.statusBars = Object.keys(counts).map(label => {
            const count = counts[label];
            const pct = Math.round((count / total) * 100);
            const color = statusColors[label] || '#a8a29e';
            return {
                label, count,
                dotStyle: `background:${color};`,
                barStyle: `width:${pct}%;background:${color};`
            };
        });

        // Monthly trend — bars scale to the busiest month; counts shown on top
        // (88% cap leaves room for the value label above the tallest bar).
        const trend = data.monthlyTrend || [];
        const maxVal = Math.max(1, ...trend.map(m => Math.max(m.sent, m.completed)));
        // A month with nothing in it draws no bar at all. Previously CSS forced a
        // 4px min-height on every bar, so empty months showed a coloured stub that
        // read as "a little activity" — or as a broken chart.
        const barHeight = (v) => (v > 0 ? Math.max(3, (v / maxVal) * 88) : 0);
        this.monthlyTrend = trend.map(m => ({
            label: m.label,
            sent: m.sent,
            completed: m.completed,
            showSent: m.sent > 0,
            showCompleted: m.completed > 0,
            sentBarStyle:      `height:${barHeight(m.sent)}%;`,
            completedBarStyle: `height:${barHeight(m.completed)}%;`,
            sentLabel:      `Sent: ${m.sent}`,
            completedLabel: `Completed: ${m.completed}`
        }));

        // Agreement list - normalize each row with canonical status + style class.
        const list = data.agreements || data.recentAgreements || [];
        this.agreements = list.map(a => ({
            ...a,
            canonicalStatus: a.canonicalStatus || a.status,
            statusClass: 'recent-status recent-status-' +
                (a.canonicalStatus || a.status || 'draft').toLowerCase()
        }));
    }

    /* ── Tabs ───────────────────────────────────────────── */
    get tabs() {
        const buckets = {
            all:       this.agreements.length,
            Draft:     0,
            Sent:      0,
            Signed:    0,
            Completed: 0,
            Expired:   0,
            Cancelled: 0
        };
        for (const a of this.agreements) {
            if (buckets[a.canonicalStatus] !== undefined) {
                buckets[a.canonicalStatus]++;
            }
        }
        const defs = [
            { key: 'all',       label: 'All' },
            { key: 'Draft',     label: 'Draft' },
            { key: 'Sent',      label: 'Sent' },
            { key: 'Signed',    label: 'Signed' },
            { key: 'Completed', label: 'Completed' },
            { key: 'Expired',   label: 'Expired' },
            { key: 'Cancelled', label: 'Cancelled' }
        ];
        return defs.map(d => ({
            key:      d.key,
            label:    d.label,
            count:    buckets[d.key] || 0,
            isActive: this.activeTab === d.key,
            cssClass: 'agr-tab' + (this.activeTab === d.key ? ' agr-tab-active' : '')
        }));
    }

    get filteredAgreements() {
        if (this.activeTab === 'all') return this.agreements;
        return this.agreements.filter(a => a.canonicalStatus === this.activeTab);
    }

    get isFilteredEmpty() {
        return !this.filteredAgreements || this.filteredAgreements.length === 0;
    }

    /* ── Pagination ─────────────────────────────────────── */
    get totalPages() {
        return Math.max(1, Math.ceil(this.filteredAgreements.length / this.pageSize));
    }

    get pagedAgreements() {
        const start = (this.currentPage - 1) * this.pageSize;
        return this.filteredAgreements.slice(start, start + this.pageSize);
    }

    get pageInfo() {
        return `Page ${this.currentPage} of ${this.totalPages}`;
    }

    get isFirstPage() { return this.currentPage <= 1; }
    get isLastPage()  { return this.currentPage >= this.totalPages; }

    get showPagination() {
        return this.filteredAgreements.length > this.pageSize;
    }

    handlePrevPage() {
        if (this.currentPage > 1) this.currentPage--;
    }

    handleNextPage() {
        if (this.currentPage < this.totalPages) this.currentPage++;
    }

    get activeTabLabel() {
        if (this.activeTab === 'all') return '';
        return this.activeTab.toLowerCase();
    }

    handleTabClick(e) {
        this.activeTab = e.currentTarget.dataset.key;
        this.currentPage = 1; // reset pagination when switching tabs
    }

    /* ── Derived display ────────────────────────────────── */
    get avgCompletionDisplay() {
        const hours = Number(this.avgCompletionHours) || 0;
        if (hours <= 0) return '-';
        // Minutes matter here: agreements are routinely signed within a few
        // minutes, and rounding those to "0h" reads as broken.
        const minutes = Math.round(hours * 60);
        if (minutes < 60) return Math.max(minutes, 1) + 'm';
        if (hours < 24) return Math.round(hours) + 'h';
        return Math.round(hours / 24) + 'd';
    }

    /* ── Actions ────────────────────────────────────────── */
    handleRefresh() {
        this.isLoading = true;
        refreshApex(this.wiredResult).finally(() => { this.isLoading = false; });
    }

    handleNavigate(e) {
        const id = e.currentTarget.dataset.id;
        if (!id) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: id,
                objectApiName: 'Agreement__c',
                actionName: 'view'
            }
        });
    }
}
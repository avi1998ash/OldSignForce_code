/**
 * @description : Dashboard data provider for SignForce analytics
 * @author      : SignForce
 */
public with sharing class DashboardController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getDashboardData() {
        Map<String, Object> data = new Map<String, Object>();

        // Status counts
        // Explicit alias 'st' on the grouped field — in a managed package the
        // implicit AggregateResult key would be namespaced (ns__Status__c),
        // so we alias it to keep ar.get(...) namespace-independent.
        List<AggregateResult> statusCounts = [
            SELECT Status__c st, COUNT(Id) cnt
            FROM Agreement__c
            WHERE Is_Template__c = false
            WITH USER_MODE
            GROUP BY Status__c
        ];
        Map<String, Integer> statusMap = new Map<String, Integer>();
        Integer total = 0;
        for (AggregateResult ar : statusCounts) {
            String status = (String) ar.get('st');
            Integer cnt = (Integer) ar.get('cnt');
            statusMap.put(status, cnt);
            total += cnt;
        }
        data.put('statusCounts', statusMap);
        data.put('totalAgreements', total);
        data.put('draftCount',     statusMap.get('Draft')     != null ? statusMap.get('Draft')     : 0);
        data.put('sentCount',      statusMap.get('Sent')      != null ? statusMap.get('Sent')      : 0);
        data.put('signedCount',    statusMap.get('Signed')    != null ? statusMap.get('Signed')    : 0);
        data.put('completedCount', statusMap.get('Completed') != null ? statusMap.get('Completed') : 0);
        data.put('declinedCount',  statusMap.get('Declined')  != null ? statusMap.get('Declined')  : 0);
        data.put('voidedCount',    statusMap.get('Voided')    != null ? statusMap.get('Voided')    : 0);

        // Completion rate
        Integer completed = statusMap.get('Completed') != null ? statusMap.get('Completed') : 0;
        Integer sent      = statusMap.get('Sent')      != null ? statusMap.get('Sent')      : 0;
        Integer declined  = statusMap.get('Declined')  != null ? statusMap.get('Declined')  : 0;
        Integer totalSentOrDone = completed + sent + declined;
        data.put('completionRate', totalSentOrDone > 0 ? Math.round((completed * 100.0) / totalSentOrDone) : 0);

        // Calculate per-record average completion time
        List<Agreement__c> completedAgrs = [
            SELECT Sent_Date__c, Completed_Date__c
            FROM Agreement__c
            WHERE Status__c = 'Completed'
            AND Completed_Date__c != null AND Sent_Date__c != null
            WITH USER_MODE
            LIMIT 100
        ];
        // Accumulate in MINUTES, and divide as Decimal.
        //
        // This used to add up whole hours with integer division, then divide the
        // total by the record count with integer division again. Any agreement
        // signed in under an hour contributed exactly 0, so an org whose
        // agreements are signed promptly reported an average of 0 — which the
        // dashboard renders as "-", i.e. "no data" on top of perfectly good data.
        // Measured here: 56 completed agreements, every one signed inside an
        // hour, true average 1.9 minutes, reported average 0.
        // Sum raw milliseconds and divide exactly once. Dividing per record - even
        // into minutes - throws away the remainder on every row: with a true
        // average of 1.9 minutes that alone under-reported it as 1.4.
        Long totalMs = 0;
        for (Agreement__c a : completedAgrs) {
            totalMs += a.Completed_Date__c.getTime() - a.Sent_Date__c.getTime();
        }
        Decimal avgHours = 0;
        if (!completedAgrs.isEmpty()) {
            avgHours = (Decimal.valueOf(totalMs) / completedAgrs.size() / (1000 * 60 * 60))
                .setScale(4, System.RoundingMode.HALF_UP);
            // Keeps a real-but-tiny average from landing back on the 0 the UI
            // reads as "no data". A minute is the smallest unit shown anyway.
            if (avgHours <= 0) avgHours = 0.0167;
        }
        data.put('avgCompletionHours', avgHours);

        // Monthly trend (last 6 months)
        List<Map<String, Object>> monthlyTrend = new List<Map<String, Object>>();
        for (Integer i = 5; i >= 0; i--) {
            Date startOfMonth = Date.today().addMonths(-i).toStartOfMonth();
            Date endOfMonth = startOfMonth.addMonths(1);
            DateTime startDT = DateTime.newInstance(startOfMonth, Time.newInstance(0,0,0,0));
            DateTime endDT   = DateTime.newInstance(endOfMonth,   Time.newInstance(0,0,0,0));

            Integer sentInMonth = [
                SELECT COUNT() FROM Agreement__c
                WHERE Sent_Date__c >= :startDT AND Sent_Date__c < :endDT
                AND Is_Template__c = false
                WITH USER_MODE
            ];
            Integer completedInMonth = [
                SELECT COUNT() FROM Agreement__c
                WHERE Completed_Date__c >= :startDT AND Completed_Date__c < :endDT
                AND Is_Template__c = false
                WITH USER_MODE
            ];

            Map<String, Object> month = new Map<String, Object>();
            month.put('label', startDT.format('MMM'));
            month.put('sent', sentInMonth);
            month.put('completed', completedInMonth);
            monthlyTrend.add(month);
        }
        data.put('monthlyTrend', monthlyTrend);

        // Agreements (broader fetch; LWC filters by tab)
        DateTime nowDT = DateTime.now();
        List<Agreement__c> agrs = [
            SELECT Id, Name, Status__c, Sent_Date__c, Completed_Date__c, CreatedDate,
                   Expiry_Date__c, Void_Reason__c
            FROM Agreement__c
            WHERE Is_Template__c = false
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 100
        ];
        Integer expiredCount = 0;
        List<Map<String, Object>> agrList = new List<Map<String, Object>>();
        for (Agreement__c a : agrs) {
            Map<String, Object> r = new Map<String, Object>();
            r.put('id',       a.Id);
            r.put('name',     a.Name);
            r.put('status',   a.Status__c);
            r.put('createdDate', a.CreatedDate.format('MMM dd, yyyy'));

            // Canonical status: maps the org's raw values to the dashboard's tabs.
            //   Voided + Void_Reason__c starts with "Expired"  -> Expired
            //   Voided                                          -> Cancelled
            //   anything past Expiry_Date__c that isn't terminal -> Expired
            //   else the raw status
            String canonical = a.Status__c;
            Boolean isExpired = false;
            Boolean isTerminal = (a.Status__c == 'Completed' || a.Status__c == 'Signed');

            if (a.Status__c == 'Voided') {
                if (String.isNotBlank(a.Void_Reason__c) && a.Void_Reason__c.toLowerCase().startsWith('expired')) {
                    canonical = 'Expired';
                    isExpired = true;
                } else {
                    canonical = 'Cancelled';
                }
            } else if (!isTerminal && a.Expiry_Date__c != null && nowDT > a.Expiry_Date__c
                       && (a.Status__c == 'Sent' || a.Status__c == 'Draft' || a.Status__c == 'Pending')) {
                canonical = 'Expired';
                isExpired = true;
            }

            if (isExpired) expiredCount++;
            r.put('canonicalStatus', canonical);
            r.put('isExpired',       isExpired);
            agrList.add(r);
        }

        data.put('expiredCount',     expiredCount);
        // Keep legacy key for any existing callers/components.
        data.put('recentAgreements', agrList);
        data.put('agreements',       agrList);

        // Pending signers count
        Integer pendingSigners = [
            SELECT COUNT() FROM Signer__c
            WHERE Status__c IN ('Pending', 'Sent')
            WITH USER_MODE
        ];
        data.put('pendingSigners', pendingSigners);

        return data;
    }
}
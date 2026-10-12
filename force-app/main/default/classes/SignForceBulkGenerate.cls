/**
 * SignForceBulkGenerate — generate one document per record, for many records.
 *
 * The single-record path (DocumentGenerationService.generate) makes an HTTP
 * callout to render each document, so a loop over hundreds of records cannot run
 * in one transaction. This chains a Queueable a few records at a time, the same
 * shape SignForceBulkSend uses for bulk signing.
 *
 * DELIBERATELY ADDITIVE. It calls the existing generate() unchanged, so a
 * document produced here is identical to one produced from the Generate Document
 * button — same merge, same filename numbering, same log row.
 *
 * PROGRESS is read back from Document_Generation_Log__c rather than from a new
 * batch field. generate() already writes one log row per attempt carrying the
 * source record, the template and the outcome, so counting rows created since
 * the batch started tells us everything without new schema. That matters here:
 * custom fields on some objects in this org deploy clean but never materialise.
 */
public with sharing class SignForceBulkGenerate {

    /* ONE record per batch execution — this is a correctness constraint, not a
       tuning knob. generate() ends in DML (the log, the ContentVersion), and a
       second generate() in the same transaction then starts with a callout,
       which Salesforce rejects as "uncommitted work pending". A scope of one
       gives each record its own transaction; 200 executions is nothing against
       the daily batch-execution limit. */
    private static final Integer SCOPE_SIZE = 1;

    /* A run of more than this is almost always a mis-click on "select all". */
    private static final Integer MAX_RECORDS = 200;

    public class BulkGenerateException extends Exception {}

    /**
     * Kicks off the run and returns immediately.
     *
     * The returned startedAt is what getStatus counts from — without it, records
     * that have been generated before would report as already finished the moment
     * the batch starts.
     */
    @AuraEnabled
    public static Map<String, Object> startBulkGenerate(Id templateId, List<Id> recordIds) {
        if (templateId == null) throw new AuraHandledException('Pick a template first.');
        if (recordIds == null || recordIds.isEmpty()) {
            throw new AuraHandledException('Pick at least one record.');
        }

        // De-dupe while keeping the order the user selected in.
        List<Id> unique = new List<Id>();
        Set<Id> seen = new Set<Id>();
        for (Id rid : recordIds) {
            if (rid != null && seen.add(rid)) unique.add(rid);
        }
        if (unique.size() > MAX_RECORDS) {
            throw new AuraHandledException(
                'That is ' + unique.size() + ' records. Please run ' + MAX_RECORDS + ' or fewer at a time.'
            );
        }

        Document_Template__c tpl = loadTemplate(templateId);

        // Every record has to belong to the template's object, or the merge would
        // fail one at a time with a confusing message per record.
        String expected = tpl.Object_API_Name__c;
        for (Id rid : unique) {
            String actual = rid.getSObjectType().getDescribe().getName();
            if (!actual.equalsIgnoreCase(expected)) {
                throw new AuraHandledException(
                    'This template is for ' + expected + ', but one of the selected records is a ' + actual + '.'
                );
            }
        }

        Datetime startedAt = Datetime.now();
        try {
            Database.executeBatch(new SignForceBulkGenerateBatch(templateId, unique), SCOPE_SIZE);
        } catch (Exception e) {
            // An org may have only five batch jobs queued or running at once.
            // Left unhandled this surfaces as a raw LimitException on a screen
            // that has just told the user their run started.
            throw new AuraHandledException(
                'The run could not be started: ' + e.getMessage()
                + ' Wait for the batches already running to finish, then try again.'
            );
        }

        return new Map<String, Object>{
            'total'      => unique.size(),
            'startedAt'  => startedAt.format('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'', 'GMT'),
            'templateId' => templateId
        };
    }

    /**
     * How far the run has got: counts the log rows generate() wrote for these
     * records since the batch began.
     *
     * Reading progress from the logs means a browser refresh mid-run picks the
     * count straight back up — there is no in-memory state to lose.
     */
    @AuraEnabled
    public static Map<String, Object> getGenerateStatus(
        Id templateId, List<Id> recordIds, String startedAtIso
    ) {
        Map<String, Object> out = new Map<String, Object>{
            'total' => recordIds == null ? 0 : recordIds.size(),
            'done' => 0, 'succeeded' => 0, 'failed' => 0, 'finished' => false
        };
        if (templateId == null || recordIds == null || recordIds.isEmpty()) return out;

        Datetime since = parseStart(startedAtIso);

        // One record can produce more than one log if it was retried, so count
        // distinct records rather than rows.
        Set<Id> succeeded = new Set<Id>();
        Set<Id> failed = new Set<Id>();
        Map<Id, String> failReason = new Map<Id, String>();
        Set<String> wanted = new Set<String>();
        for (Id rid : recordIds) wanted.add(String.valueOf(rid));

        for (Document_Generation_Log__c lg : [
            SELECT Source_Record_Id__c, Status__c, Error_Message__c, Output_Filename__c
            FROM Document_Generation_Log__c
            WHERE Document_Template__c = :templateId
            AND Source_Record_Id__c IN :wanted
            AND CreatedDate >= :since
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT 2000
        ]) {
            if (String.isBlank(lg.Source_Record_Id__c)) continue;
            Id rid = (Id) lg.Source_Record_Id__c;
            if (lg.Status__c == 'Success') {
                succeeded.add(rid); failed.remove(rid); failReason.remove(rid);
            } else if (lg.Status__c == 'Failure' && !succeeded.contains(rid)) {
                failed.add(rid);
                failReason.put(rid, lg.Error_Message__c);
            }
        }

        Integer done = succeeded.size() + failed.size();
        out.put('succeeded', succeeded.size());
        out.put('failed', failed.size());
        out.put('done', done);
        out.put('finished', done >= recordIds.size());

        // Per-record outcome, in the order the caller passed them. A bare
        // "2 failed" leaves the user with no idea WHICH two or why, and the log
        // tab is not somewhere a non-admin can go looking.
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Id rid : recordIds) {
            String st = succeeded.contains(rid) ? 'Success'
                      : (failed.contains(rid) ? 'Failure' : 'Waiting');
            rows.add(new Map<String, Object>{
                'recordId' => rid,
                'status'   => st,
                'error'    => failReason.get(rid)
            });
        }
        out.put('rows', rows);
        return out;
    }

    /**
     * What the caller is holding: the object behind a set of record ids.
     *
     * The flow screen and the list action receive bare ids with no object name
     * attached. Deriving it here from the id prefix is what lets ONE flow and
     * ONE component serve every object — the alternative was a copy of the host
     * page per object, each with the object name hard-coded.
     */
    @AuraEnabled
    public static Map<String, Object> describeIds(List<Id> recordIds) {
        if (recordIds == null || recordIds.isEmpty()) {
            return new Map<String, Object>{ 'count' => 0 };
        }

        Schema.SObjectType sot = recordIds[0].getSObjectType();
        String apiName = sot.getDescribe().getName();

        // Mixed selections cannot happen from a single list view, but ids can
        // arrive from anywhere once this is callable from Flow — so check.
        for (Id rid : recordIds) {
            if (rid != null && rid.getSObjectType() != sot) {
                throw new AuraHandledException(
                    'The selected records are not all the same type of record.'
                );
            }
        }

        return new Map<String, Object>{
            'objectApiName' => apiName,
            'objectLabel'   => sot.getDescribe().getLabel(),
            'objectLabelPlural' => sot.getDescribe().getLabelPlural(),
            'count'         => recordIds.size(),
            'records'       => namesFor(sot, apiName, recordIds)
        };
    }

    /**
     * The selected records by name, so the screen can show WHICH records it is
     * about to act on instead of only how many. A count alone gives the user no
     * way to catch a mis-click before 200 documents exist.
     *
     * The name field is found from the describe rather than assumed to be
     * "Name": Task, Case and several standard objects do not have one, and a
     * custom object can use an auto-number.
     */
    private static List<Map<String, Object>> namesFor(
        Schema.SObjectType sot, String apiName, List<Id> recordIds
    ) {
        Map<Id, String> byId = namesByIds(apiName, new Set<Id>(recordIds));

        // Iterate the INPUT order, not the query result: the user ticked rows in
        // a particular order and a row they cannot see (no sharing) still has to
        // appear, otherwise the count and the list disagree.
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Id rid : recordIds) {
            out.add(new Map<String, Object>{
                'id'   => rid,
                'name' => byId.containsKey(rid) ? byId.get(rid) : String.valueOf(rid)
            });
        }
        return out;
    }

    /**
     * Record names for a set of ids on one object, in a single query.
     *
     * The name field is read from the describe rather than assumed to be "Name":
     * Task, Case and several standard objects do not have one, and a custom
     * object can use an auto-number. An id with no entry in the returned map is
     * one the running user cannot see, or one that has been deleted.
     */
    private static Map<Id, String> namesByIds(String apiName, Set<Id> ids) {
        Map<Id, String> byId = new Map<Id, String>();
        if (ids == null || ids.isEmpty() || String.isBlank(apiName)) return byId;

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(apiName);
        if (sot == null) return byId;          // object dropped since the log was written

        Schema.DescribeSObjectResult objDesc = sot.getDescribe();
        String nameField = null;
        for (Schema.SObjectField f : objDesc.fields.getMap().values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (d.isNameField() && d.isAccessible()) { nameField = d.getName(); break; }
        }
        if (nameField == null) return byId;

        // Both halves of the query come from the describe, so they are known-good
        // identifiers rather than anything the caller supplied.
        List<Id> idList = new List<Id>(ids);
        String soql = 'SELECT Id, ' + nameField + ' FROM ' + objDesc.getName()
                    + ' WHERE Id IN :idList LIMIT 200';
        for (SObject s : Database.query(soql, AccessLevel.USER_MODE)) {
            byId.put(s.Id, String.valueOf(s.get(nameField)));
        }
        return byId;
    }

    /**
     * The individual documents behind one Recent Activity row.
     *
     * The activity table is an aggregate — "Test / Account / 43 completed" — so
     * after a bulk run there was nowhere at all that listed WHICH documents were
     * produced. Document_Generation_Log__c has no tab, and the per-record card
     * only shows one record at a time, so the only way to see the result of a
     * 43-record run was to open 43 records.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getActivityDetail(
        Id templateId, String objectApiName, Integer hoursBack
    ) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (templateId == null || String.isBlank(objectApiName)) return out;

        Integer hrs = (hoursBack == null || hoursBack <= 0) ? 168 : hoursBack;
        Datetime since = Datetime.now().addHours(-hrs);

        List<Document_Generation_Log__c> logs = [
            SELECT Id, Source_Record_Id__c, Status__c, Error_Message__c,
                   Output_Filename__c, Output_File_Id__c, Duration_Ms__c,
                   CreatedDate, CreatedBy.Name
            FROM Document_Generation_Log__c
            WHERE Document_Template__c = :templateId
            AND Source_Object_Api_Name__c = :objectApiName
            AND CreatedDate >= :since
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];
        if (logs.isEmpty()) return out;

        Set<Id> rids = new Set<Id>();
        for (Document_Generation_Log__c lg : logs) {
            if (String.isNotBlank(lg.Source_Record_Id__c)) rids.add((Id) lg.Source_Record_Id__c);
        }
        Map<Id, String> names = namesByIds(objectApiName, rids);

        for (Document_Generation_Log__c lg : logs) {
            Id rid = String.isBlank(lg.Source_Record_Id__c) ? null : (Id) lg.Source_Record_Id__c;
            out.add(new Map<String, Object>{
                'logId'      => lg.Id,
                'recordId'   => rid,
                // A deleted record still has a log row, and its name is the only
                // thing that would go blank — so say so rather than show nothing.
                'recordName' => (rid != null && names.containsKey(rid))
                                    ? names.get(rid)
                                    : 'Record no longer available',
                'status'     => lg.Status__c,
                'error'      => lg.Error_Message__c,
                'filename'   => lg.Output_Filename__c,
                'fileId'     => lg.Output_File_Id__c,
                'createdAt'  => lg.CreatedDate,
                'createdBy'  => lg.CreatedBy == null ? '' : lg.CreatedBy.Name
            });
        }
        return out;
    }

    /**
     * Recent generation activity, one row per template + object.
     *
     * Rolled up from the same log rows getGenerateStatus reads, so it survives a
     * page reload and shows runs someone else started — the in-browser batch
     * state cannot do either.
     *
     * Returns: { templateId, templateName, objectApiName, succeeded, failed,
     *            total, lastRun }
     */
    @AuraEnabled
    public static List<Map<String, Object>> getRecentActivity(Integer hoursBack) {
        Integer hrs = (hoursBack == null || hoursBack <= 0) ? 168 : hoursBack;
        Datetime since = Datetime.now().addHours(-hrs);

        // Keyed "templateId|object" so one template used on two objects stays two
        // rows rather than a misleading combined total.
        Map<String, Map<String, Object>> byKey = new Map<String, Map<String, Object>>();
        Set<Id> templateIds = new Set<Id>();

        for (AggregateResult ar : [
            SELECT Document_Template__c tplId,
                   Source_Object_Api_Name__c obj,
                   Status__c st,
                   COUNT(Id) cnt,
                   MAX(CreatedDate) lastRun
            FROM Document_Generation_Log__c
            WHERE CreatedDate >= :since
            AND Document_Template__c != null
            WITH USER_MODE
            GROUP BY Document_Template__c, Source_Object_Api_Name__c, Status__c
            ORDER BY MAX(CreatedDate) DESC
            LIMIT 300
        ]) {
            Id tplId = (Id) ar.get('tplId');
            String obj = (String) ar.get('obj');
            String st  = (String) ar.get('st');
            Integer cnt = (Integer) ar.get('cnt');
            Datetime lastRun = (Datetime) ar.get('lastRun');

            templateIds.add(tplId);
            String key = tplId + '|' + obj;

            Map<String, Object> row = byKey.get(key);
            if (row == null) {
                row = new Map<String, Object>{
                    'templateId' => tplId, 'templateName' => '',
                    'objectApiName' => obj,
                    'succeeded' => 0, 'failed' => 0, 'total' => 0,
                    'lastRun' => lastRun
                };
                byKey.put(key, row);
            }

            if (st == 'Success') row.put('succeeded', ((Integer) row.get('succeeded')) + cnt);
            else if (st == 'Failure') row.put('failed', ((Integer) row.get('failed')) + cnt);
            row.put('total', ((Integer) row.get('total')) + cnt);

            Datetime seen = (Datetime) row.get('lastRun');
            if (seen == null || lastRun > seen) row.put('lastRun', lastRun);
        }

        // Names separately: grouping by a relationship field is allowed but makes
        // the aggregate harder to read for no gain.
        Map<Id, String> names = new Map<Id, String>();
        for (Document_Template__c t : [
            SELECT Id, Name FROM Document_Template__c WHERE Id IN :templateIds WITH USER_MODE
        ]) {
            names.put(t.Id, t.Name);
        }

        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Map<String, Object> row : byKey.values()) {
            row.put('templateName', names.get((Id) row.get('templateId')));
            out.add(row);
        }
        return out;
    }

    /**
     * Records of the template's object, for the picker. Blank term returns the
     * most recently touched ones so the list is never empty on open.
     */
    @AuraEnabled
    public static List<Map<String, Object>> searchRecords(Id templateId, String term) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        if (templateId == null) return rows;

        Document_Template__c tpl = loadTemplate(templateId);
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(tpl.Object_API_Name__c);
        if (sot == null) {
            throw new AuraHandledException(
                'The object this template targets (' + tpl.Object_API_Name__c + ') no longer exists.'
            );
        }
        Schema.DescribeSObjectResult objDesc = sot.getDescribe();
        if (!objDesc.isAccessible()) {
            throw new AuraHandledException('You do not have access to ' + objDesc.getLabel() + ' records.');
        }
        if (!objDesc.fields.getMap().containsKey('name')) {
            throw new AuraHandledException(
                objDesc.getLabel() + ' has no Name field, so records cannot be listed here.'
            );
        }

        // The object name comes from the template record, and it is checked
        // against the global describe above, so it is safe to inline. The search
        // term is bound, never concatenated.
        String soql = 'SELECT Id, Name FROM ' + objDesc.getName();
        String pattern = '%' + String.escapeSingleQuotes(String.isBlank(term) ? '' : term.trim()) + '%';
        if (String.isNotBlank(term)) soql += ' WHERE Name LIKE :pattern';
        soql += ' ORDER BY LastModifiedDate DESC LIMIT 100';

        for (SObject rec : Database.query(soql, AccessLevel.USER_MODE)) {
            rows.add(new Map<String, Object>{
                'id'   => rec.get('Id'),
                'name' => rec.get('Name')
            });
        }
        return rows;
    }

    /* ── internals ──────────────────────────────────────────────────── */

    private static Document_Template__c loadTemplate(Id templateId) {
        List<Document_Template__c> tpls = [
            SELECT Id, Name, Object_API_Name__c, Active__c, Template_File_Id__c
            FROM Document_Template__c WHERE Id = :templateId WITH USER_MODE LIMIT 1
        ];
        if (tpls.isEmpty()) throw new AuraHandledException('Template not found.');
        Document_Template__c tpl = tpls[0];
        if (tpl.Active__c != true) {
            throw new AuraHandledException('"' + tpl.Name + '" is inactive. Activate it before running a batch.');
        }
        if (String.isBlank(tpl.Template_File_Id__c)) {
            throw new AuraHandledException('"' + tpl.Name + '" has no uploaded document yet.');
        }
        return tpl;
    }

    /** Tolerant of the ISO string the client sends back; falls back to an hour ago. */
    private static Datetime parseStart(String iso) {
        if (String.isBlank(iso)) return Datetime.now().addHours(-1);
        try {
            return (Datetime) JSON.deserialize('"' + iso + '"', Datetime.class);
        } catch (Exception e) {
            return Datetime.now().addHours(-1);
        }
    }

    /* The work itself is in SignForceBulkGenerateBatch — Salesforce only lets a
       TOP-LEVEL class implement Database.Batchable, so it cannot live here. */
}
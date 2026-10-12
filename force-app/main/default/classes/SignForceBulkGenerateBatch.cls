/**
 * SignForceBulkGenerateBatch — runs one document generation per record.
 *
 * BATCH, NOT A QUEUEABLE CHAIN. SignForceBulkGenerate used to enqueue a
 * Queueable per record, each one enqueueing the next. That works in production
 * but Developer Edition and trial orgs cap chained Queueable depth at 5: a
 * 13-record run produced 4 documents and the next link died with "Maximum
 * stack depth has been reached". Nothing was recorded against the remaining
 * records, so the progress bar sat at 31% for ever and neither the bulk console
 * nor the list-view screen had any way to learn the run was over.
 *
 * Batch Apex has no equivalent cap, and it keeps the property the chain was
 * built for: every execute() is its own transaction, so a scope of ONE record
 * never hits "uncommitted work pending" when generate() ends in DML and the
 * next record starts with a callout.
 *
 * It lives in its own file because Salesforce only lets a TOP-LEVEL class
 * implement Database.Batchable — as an inner class it fails to compile with
 * "Only top-level classes can implement Database.Batchable<Id>".
 */
public with sharing class SignForceBulkGenerateBatch
        implements Database.Batchable<Id>, Database.AllowsCallouts {

    private final Id templateId;
    private final List<Id> recordIds;
    /** Run start, so finish() can tell this run's log rows from an earlier run's. */
    private final Datetime startedAt;

    public SignForceBulkGenerateBatch(Id templateId, List<Id> recordIds) {
        this.templateId = templateId;
        this.recordIds  = recordIds;
        this.startedAt  = Datetime.now();
    }

    /**
     * The id list is iterated directly rather than through a QueryLocator.
     *
     * A QueryLocator quietly drops an id whose record was deleted between being
     * selected and the run starting: generate() would never be called for it and
     * no log row would be written. Progress is counted from those log rows, so
     * `done` could never reach `total` and the run would look stuck at 92%.
     * Passing every id through means generate() attempts it and records the
     * failure like any other.
     */
    public Iterable<Id> start(Database.BatchableContext ctx) {
        return recordIds;
    }

    public void execute(Database.BatchableContext ctx, List<Id> scope) {
        for (Id rid : scope) {
            try {
                // generate() writes its own log row either way, and that row is
                // what getGenerateStatus counts — so a failure here needs no
                // extra bookkeeping, only to not stop the rest of the batch.
                DocumentGenerationService.generate(templateId, rid);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'BulkGenerate: ' + rid + ' failed: ' + e.getMessage());
            }
        }
    }

    /**
     * Closes out any record this run never logged.
     *
     * Progress is counted purely from Document_Generation_Log__c rows, and the
     * catch in execute() was assumed to guarantee one row per record. It does
     * not: a governor/platform failure such as "ContentPublication Limit
     * exceeded" is not catchable, so the whole execute() transaction rolls back
     * — generate()'s log row included. Those records then have no row at all,
     * `done` never reaches `total`, and the console sits on "Working" for ever
     * with nothing created and nothing reported failed. Observed exactly that:
     * four batch executions ended with NumberOfErrors > 0 and the run never
     * reached a terminal state.
     *
     * Writing the missing rows here means the run always ends somewhere the UI
     * can read, and the reason travels with it.
     */
    public void finish(Database.BatchableContext ctx) {
        try {
            if (recordIds == null || recordIds.isEmpty()) return;

            Set<String> wanted = new Set<String>();
            for (Id rid : recordIds) wanted.add(String.valueOf(rid));

            Set<String> logged = new Set<String>();
            for (Document_Generation_Log__c lg : [
                SELECT Source_Record_Id__c
                FROM Document_Generation_Log__c
                WHERE Document_Template__c = :templateId
                AND Source_Record_Id__c IN :wanted
                AND CreatedDate >= :startedAt
                WITH USER_MODE
                LIMIT 2000
            ]) {
                if (String.isNotBlank(lg.Source_Record_Id__c)) logged.add(lg.Source_Record_Id__c);
            }

            wanted.removeAll(logged);
            if (wanted.isEmpty()) return;

            // The platform keeps the real reason on the job itself; execute()
            // never saw it, so read it back rather than inventing a message.
            String reason = 'Generation stopped before it could be recorded.';
            List<AsyncApexJob> jobs = [
                SELECT ExtendedStatus, NumberOfErrors
                FROM AsyncApexJob WHERE Id = :ctx.getJobId() LIMIT 1
            ];
            if (!jobs.isEmpty() && String.isNotBlank(jobs[0].ExtendedStatus)) {
                reason = jobs[0].ExtendedStatus;
            }
            if (reason.length() > 255) reason = reason.substring(0, 255);

            List<Document_Generation_Log__c> misses = new List<Document_Generation_Log__c>();
            for (String rid : wanted) {
                misses.add(new Document_Generation_Log__c(
                    Document_Template__c = templateId,
                    Source_Record_Id__c  = rid,
                    Status__c            = 'Failure',
                    Error_Message__c     = reason
                ));
            }
            SignForceFLS.requireCreateable(Document_Generation_Log__c.SObjectType);
            Database.insert(misses, false, AccessLevel.USER_MODE);

        } catch (Exception e) {
            // Best effort. A failure here must not mask the run itself.
            System.debug(LoggingLevel.WARN,
                'BulkGenerate finish() reconcile failed: ' + e.getMessage());
        }
    }
}
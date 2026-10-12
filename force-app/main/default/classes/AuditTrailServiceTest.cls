/**
 * AuditTrailServiceTest - coverage for AuditTrailService (internal callers): both log overloads, notes truncation,
 * and the best-effort (never throws) contract.
 */
@isTest
private class AuditTrailServiceTest {

    private static Agreement__c makeAgreement() {
        Agreement__c agr = AgreementService.createAgreement(
            'Audit Internal Test', 'Contract', 'Sequential', 'msg', null);
        return agr;
    }

    @isTest
    static void log_fiveArg_insertsEvent() {
        Agreement__c agr = makeAgreement();
        Test.startTest();
        AuditTrailService.log(agr.Id, 'Internal Viewed', 'g@example.com', '1.2.3.4', 'UA/1.0');
        Test.stopTest();
        List<Signing_Event__c> evts = [SELECT Action__c, Signer_Email__c, IP_Address__c, User_Agent__c, Notes__c
                                       FROM Signing_Event__c WHERE Agreement__c = :agr.Id AND Action__c = 'Internal Viewed'];
        System.assertEquals(1, evts.size());
        System.assertEquals('g@example.com', evts[0].Signer_Email__c);
        System.assertEquals('1.2.3.4', evts[0].IP_Address__c);
        System.assertEquals('UA/1.0', evts[0].User_Agent__c);
        System.assertEquals(null, evts[0].Notes__c);
    }

    @isTest
    static void log_sixArg_storesNotes() {
        Agreement__c agr = makeAgreement();
        Test.startTest();
        AuditTrailService.log(agr.Id, 'Internal Failed', 'g@example.com', '1.2.3.4', 'UA/1.0', 'reason text');
        Test.stopTest();
        List<Signing_Event__c> evts = [SELECT Notes__c, User_Agent__c FROM Signing_Event__c
                                       WHERE Agreement__c = :agr.Id AND Action__c = 'Internal Failed'];
        System.assertEquals(1, evts.size());
        System.assertEquals('reason text', evts[0].Notes__c);
        System.assertEquals('UA/1.0', evts[0].User_Agent__c);
    }

    @isTest
    static void log_sixArg_truncatesNotesTo255() {
        Agreement__c agr = makeAgreement();
        String longNotes = 'x'.repeat(400);
        Test.startTest();
        AuditTrailService.log(agr.Id, 'Long Notes', 'g@example.com', null, null, longNotes);
        Test.stopTest();
        Signing_Event__c e = [SELECT Notes__c FROM Signing_Event__c WHERE Agreement__c = :agr.Id AND Action__c = 'Long Notes' LIMIT 1];
        System.assertEquals(255, e.Notes__c.length());
    }

    @isTest
    static void log_sixArg_nullNotes_isAllowed() {
        Agreement__c agr = makeAgreement();
        AuditTrailService.log(agr.Id, 'Null Notes', 'g@example.com', null, null, null);
        System.assertEquals(1, [SELECT COUNT() FROM Signing_Event__c WHERE Agreement__c = :agr.Id AND Action__c = 'Null Notes']);
    }

    @isTest
    static void log_isBestEffort_neverThrows() {
        // No agreement => the insert fails; the failure must be swallowed, not thrown.
        AuditTrailService.log(null, 'No Agreement', 'g@example.com', null, null);
        AuditTrailService.log(null, 'No Agreement', 'g@example.com', null, null, 'note');
        System.assertEquals(0, [SELECT COUNT() FROM Signing_Event__c WHERE Action__c = 'No Agreement']);
    }
}

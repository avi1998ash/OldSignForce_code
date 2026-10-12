/**
 * AgentforceAddSignerTest — DISABLED.
 *
 * Agentforce is switched off in this build, so the class under test no longer
 * does the work these methods asserted on. The original test body is preserved
 * below, line-commented, and comes back with the feature.
 *
 * Coverage for the disabled surface lives in AgentforceDisabledTest.
 */
@IsTest
private class AgentforceAddSignerTest {

    /* ═══ ORIGINAL TESTS — nothing below executes ═══ */
// @IsTest
// private class AgentforceAddSignerTest {
//
//     // ─── Happy path: add signer by agreementId ────────────────────────────────
//     @IsTest
//     static void addSigner_byAgreementId_success() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('AddSigner Test NDA');
//
//         AgentforceAddSigner.Request req = new AgentforceAddSigner.Request();
//         req.agreementId   = String.valueOf(agr.Id);
//         req.signerName    = 'John Smith';
//         req.email         = 'john.smith@example.com';
//         req.role          = 'Signer';
//         req.signingOrder  = 1;
//
//         Test.startTest();
//         List<AgentforceAddSigner.Response> results =
//             AgentforceAddSigner.getInvocableActions(
//                 new List<AgentforceAddSigner.Request>{ req }
//             );
//         Test.stopTest();
//
//         System.assertEquals(1, results.size());
//         System.assertEquals(true, results[0].success, results[0].result);
//         System.assertNotEquals(null, results[0].result);
//     }
//
//     // ─── Happy path: add signer by agreementName ──────────────────────────────
//     @IsTest
//     static void addSigner_byAgreementName_success() {
//         TestDataFactory.createDraftAgreement('AddSigner ByName NDA');
//
//         AgentforceAddSigner.Request req = new AgentforceAddSigner.Request();
//         req.agreementName = 'AddSigner ByName NDA';
//         req.signerName    = 'Jane Doe';
//         req.email         = 'jane.doe@example.com';
//         req.role          = 'Signer';
//         req.signingOrder  = 1;
//
//         Test.startTest();
//         List<AgentforceAddSigner.Response> results =
//             AgentforceAddSigner.getInvocableActions(
//                 new List<AgentforceAddSigner.Request>{ req }
//             );
//         Test.stopTest();
//
//         System.assertEquals(true, results[0].success, results[0].result);
//     }
//
//     // ─── Happy path: role = Approver ──────────────────────────────────────────
//     @IsTest
//     static void addSigner_approverRole_success() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('AddSigner Approver NDA');
//
//         AgentforceAddSigner.Request req = new AgentforceAddSigner.Request();
//         req.agreementId  = String.valueOf(agr.Id);
//         req.signerName   = 'Alice Approver';
//         req.email        = 'alice.approver@example.com';
//         req.role         = 'Approver';
//         req.signingOrder = 1;
//
//         Test.startTest();
//         List<AgentforceAddSigner.Response> results =
//             AgentforceAddSigner.getInvocableActions(
//                 new List<AgentforceAddSigner.Request>{ req }
//             );
//         Test.stopTest();
//
//         System.assertEquals(true, results[0].success, results[0].result);
//     }
//
//     // ─── Happy path: role = CC ────────────────────────────────────────────────
//     @IsTest
//     static void addSigner_ccRole_success() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('AddSigner CC NDA');
//
//         AgentforceAddSigner.Request req = new AgentforceAddSigner.Request();
//         req.agreementId  = String.valueOf(agr.Id);
//         req.signerName   = 'Bob CC';
//         req.email        = 'bob.cc@example.com';
//         req.role         = 'CC';
//         req.signingOrder = 1;
//
//         Test.startTest();
//         List<AgentforceAddSigner.Response> results =
//             AgentforceAddSigner.getInvocableActions(
//                 new List<AgentforceAddSigner.Request>{ req }
//             );
//         Test.stopTest();
//
//         System.assertEquals(true, results[0].success, results[0].result);
//     }
//
//     // ─── Happy path: null role falls back to default ──────────────────────────
//     @IsTest
//     static void addSigner_nullRole_usesDefault() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('AddSigner NullRole NDA');
//
//         AgentforceAddSigner.Request req = new AgentforceAddSigner.Request();
//         req.agreementId  = String.valueOf(agr.Id);
//         req.signerName   = 'Default Role';
//         req.email        = 'default.role@example.com';
//         req.role         = null;
//         req.signingOrder = 1;
//
//         Test.startTest();
//         List<AgentforceAddSigner.Response> results =
//             AgentforceAddSigner.getInvocableActions(
//                 new List<AgentforceAddSigner.Request>{ req }
//             );
//         Test.stopTest();
//
//         System.assertEquals(true, results[0].success, results[0].result);
//     }
//
//     // ─── Happy path: null signingOrder falls back to default ──────────────────
//     @IsTest
//     static void addSigner_nullSigningOrder_usesDefault() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('AddSigner NullOrder NDA');
//
//         AgentforceAddSigner.Request req = new AgentforceAddSigner.Request();
//         req.agreementId  = String.valueOf(agr.Id);
//         req.signerName   = 'No Order';
//         req.email        = 'no.order@example.com';
//         req.role         = 'Signer';
//         req.signingOrder = null;
//
//         Test.startTest();
//         List<AgentforceAddSigner.Response> results =
//             AgentforceAddSigner.getInvocableActions(
//                 new List<AgentforceAddSigner.Request>{ req }
//             );
//         Test.stopTest();
//
//         System.assertEquals(true, results[0].success, results[0].result);
//     }
//
//     // ─── Failure: null request hits catch block ───────────────────────────────
//     @IsTest
//     static void addSigner_nullRequest_returnsFailure() {
//         Test.startTest();
//         List<AgentforceAddSigner.Response> results =
//             AgentforceAddSigner.getInvocableActions(
//                 new List<AgentforceAddSigner.Request>{ null }
//             );
//         Test.stopTest();
//
//         System.assertEquals(1, results.size());
//         System.assertEquals(false, results[0].success);
//         System.assert(results[0].result.startsWith('Error:'), results[0].result);
//     }
//
//     // ─── Failure: blank agreementId and agreementName ─────────────────────────
//     @IsTest
//     static void addSigner_noAgreementIdentifier_returnsFailure() {
//         AgentforceAddSigner.Request req = new AgentforceAddSigner.Request();
//         req.agreementId   = null;
//         req.agreementName = null;
//         req.signerName    = 'Ghost';
//         req.email         = 'ghost@example.com';
//         req.role          = 'Signer';
//
//         Test.startTest();
//         List<AgentforceAddSigner.Response> results =
//             AgentforceAddSigner.getInvocableActions(
//                 new List<AgentforceAddSigner.Request>{ req }
//             );
//         Test.stopTest();
//
//         System.assertEquals(false, results[0].success);
//         System.assert(results[0].result.startsWith('Error:'), results[0].result);
//     }
//
//     // ─── Failure: agreement not found by name ─────────────────────────────────
//     @IsTest
//     static void addSigner_agreementNotFound_returnsFailure() {
//         AgentforceAddSigner.Request req = new AgentforceAddSigner.Request();
//         req.agreementName = 'ZZZNONEXISTENT_99999';
//         req.signerName    = 'Nobody';
//         req.email         = 'nobody@example.com';
//         req.role          = 'Signer';
//
//         Test.startTest();
//         List<AgentforceAddSigner.Response> results =
//             AgentforceAddSigner.getInvocableActions(
//                 new List<AgentforceAddSigner.Request>{ req }
//             );
//         Test.stopTest();
//
//         System.assertEquals(false, results[0].success);
//         System.assert(results[0].result.startsWith('Error:'), results[0].result);
//     }
//
//     // ─── Failure: blank email ─────────────────────────────────────────────────
//     @IsTest
//     static void addSigner_blankEmail_returnsFailure() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('AddSigner BlankEmail NDA');
//
//         AgentforceAddSigner.Request req = new AgentforceAddSigner.Request();
//         req.agreementId = String.valueOf(agr.Id);
//         req.signerName  = 'No Email';
//         req.email       = '';
//         req.role        = 'Signer';
//
//         Test.startTest();
//         List<AgentforceAddSigner.Response> results =
//             AgentforceAddSigner.getInvocableActions(
//                 new List<AgentforceAddSigner.Request>{ req }
//             );
//         Test.stopTest();
//
//         System.assertEquals(false, results[0].success);
//     }
//
//     // ─── Batch: multiple requests processed correctly ─────────────────────────
//     @IsTest
//     static void addSigner_batchRequests_allProcessed() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('AddSigner Batch NDA');
//
//         AgentforceAddSigner.Request req1 = new AgentforceAddSigner.Request();
//         req1.agreementId  = String.valueOf(agr.Id);
//         req1.signerName   = 'Batch One';
//         req1.email        = 'batch.one@example.com';
//         req1.role         = 'Signer';
//         req1.signingOrder = 1;
//
//         AgentforceAddSigner.Request req2 = new AgentforceAddSigner.Request();
//         req2.agreementId  = String.valueOf(agr.Id);
//         req2.signerName   = 'Batch Two';
//         req2.email        = 'batch.two@example.com';
//         req2.role         = 'Approver';
//         req2.signingOrder = 2;
//
//         // Third request deliberately invalid to test mixed batch
//         AgentforceAddSigner.Request req3 = new AgentforceAddSigner.Request();
//         req3.agreementId  = null;
//         req3.agreementName = null;
//         req3.email        = 'fail@example.com';
//
//         Test.startTest();
//         List<AgentforceAddSigner.Response> results =
//             AgentforceAddSigner.getInvocableActions(
//                 new List<AgentforceAddSigner.Request>{ req1, req2, req3 }
//             );
//         Test.stopTest();
//
//         System.assertEquals(3, results.size());
//         System.assertEquals(true,  results[0].success, results[0].result);
//         System.assertEquals(true,  results[1].success, results[1].result);
//         System.assertEquals(false, results[2].success, results[2].result);
//     }
//
//     // ─── Response fields populated correctly on success ───────────────────────
//     @IsTest
//     static void addSigner_successResponse_hasResultText() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('AddSigner ResponseCheck NDA');
//
//         AgentforceAddSigner.Request req = new AgentforceAddSigner.Request();
//         req.agreementId  = String.valueOf(agr.Id);
//         req.signerName   = 'Response Check';
//         req.email        = 'response.check@example.com';
//         req.role         = 'Signer';
//         req.signingOrder = 1;
//
//         Test.startTest();
//         List<AgentforceAddSigner.Response> results =
//             AgentforceAddSigner.getInvocableActions(
//                 new List<AgentforceAddSigner.Request>{ req }
//             );
//         Test.stopTest();
//
//         System.assertEquals(true, results[0].success);
//         System.assertNotEquals(null, results[0].result);
//         // result should mention the email or agreement
//         System.assert(
//             results[0].result.contains('response.check@example.com')
//             || results[0].result.contains('AddSigner ResponseCheck NDA'),
//             results[0].result
//         );
//     }
// }
}
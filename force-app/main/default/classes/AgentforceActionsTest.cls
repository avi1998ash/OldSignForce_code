/**
 * AgentforceActionsTest — DISABLED.
 *
 * Agentforce is switched off in this build, so the class under test no longer
 * does the work these methods asserted on. The original test body is preserved
 * below, line-commented, and comes back with the feature.
 *
 * Coverage for the disabled surface lives in AgentforceDisabledTest.
 */
@IsTest
private class AgentforceActionsTest {

    /* ═══ ORIGINAL TESTS — nothing below executes ═══ */
// @IsTest
// private class AgentforceActionsTest {
//
//     private static Agreement__c makeAgreement(String name) {
//         Agreement__c agr = AgreementService.createAgreement(name, 'Standard', 'Parallel', 'Please sign', DateTime.now().addDays(7));
//         return agr;
//     }
//
//     // ─── getStatus: blank / null agreementName ───────────────────────────────
//     @IsTest
//     static void getStatus_blankName_returnsPrompt() {
//         AgentforceActions.StatusRequest req = new AgentforceActions.StatusRequest();
//         req.agreementName = '   ';
//         List<AgentforceActions.StatusResponse> results =
//             AgentforceActions.getStatus(new List<AgentforceActions.StatusRequest>{ req });
//         System.assertEquals(1, results.size());
//         System.assert(results[0].resultSummary.contains('Please tell me'), results[0].resultSummary);
//     }
//
//     @IsTest
//     static void getStatus_nullName_returnsPrompt() {
//         AgentforceActions.StatusRequest req = new AgentforceActions.StatusRequest();
//         req.agreementName = null;
//         List<AgentforceActions.StatusResponse> results =
//             AgentforceActions.getStatus(new List<AgentforceActions.StatusRequest>{ req });
//         System.assertEquals(1, results.size());
//         System.assert(results[0].resultSummary.contains('Please tell me'), results[0].resultSummary);
//     }
//
//     // ─── getStatus: no matching record ───────────────────────────────────────
//     @IsTest
//     static void getStatus_noMatch_returnsNotFound() {
//         AgentforceActions.StatusRequest req = new AgentforceActions.StatusRequest();
//         req.agreementName = 'ZZZNONEXISTENT_XYZ_12345';
//         List<AgentforceActions.StatusResponse> results =
//             AgentforceActions.getStatus(new List<AgentforceActions.StatusRequest>{ req });
//         System.assertEquals(1, results.size());
//         System.assert(results[0].resultSummary.contains('No agreement found'), results[0].resultSummary);
//     }
//
//     // ─── getStatus: single matching record ───────────────────────────────────
//     @IsTest
//     static void getStatus_singleMatch_returnsStatus() {
//         Agreement__c agr = makeAgreement('AgentforceActions Single Test NDA');
//         AgentforceActions.StatusRequest req = new AgentforceActions.StatusRequest();
//         req.agreementName = 'AgentforceActions Single Test NDA';
//         List<AgentforceActions.StatusResponse> results =
//             AgentforceActions.getStatus(new List<AgentforceActions.StatusRequest>{ req });
//         System.assertEquals(1, results.size());
//         System.assertNotEquals(null, results[0].agreementId);
//         System.assert(results[0].resultSummary.contains('AgentforceActions Single Test NDA'), results[0].resultSummary);
//     }
//
//     // ─── getStatus: multiple matching records ────────────────────────────────
//     @IsTest
//     static void getStatus_multipleMatches_returnsAmbiguous() {
//         makeAgreement('AgentforceActions Multi NDA Alpha');
//         makeAgreement('AgentforceActions Multi NDA Beta');
//         makeAgreement('AgentforceActions Multi NDA Gamma');
//         AgentforceActions.StatusRequest req = new AgentforceActions.StatusRequest();
//         req.agreementName = 'AgentforceActions Multi NDA';
//         List<AgentforceActions.StatusResponse> results =
//             AgentforceActions.getStatus(new List<AgentforceActions.StatusRequest>{ req });
//         System.assertEquals(1, results.size());
//         System.assert(results[0].resultSummary.contains('Which one did you mean?'), results[0].resultSummary);
//     }
//
//     // ─── getStatus: single match WITH expiry date ─────────────────────────────
//     @IsTest
//     static void getStatus_singleMatchWithExpiry_containsExpiryText() {
//         Agreement__c agr = makeAgreement('AgentforceActions Expiry Test NDA');
//         // Set expiry date directly if AgreementService doesn't expose it
//         agr.Expiry_Date__c = Date.today().addDays(30);
//         update agr;
//
//         AgentforceActions.StatusRequest req = new AgentforceActions.StatusRequest();
//         req.agreementName = 'AgentforceActions Expiry Test NDA';
//         List<AgentforceActions.StatusResponse> results =
//             AgentforceActions.getStatus(new List<AgentforceActions.StatusRequest>{ req });
//         System.assertEquals(1, results.size());
//         System.assert(
//             results[0].resultSummary.contains('expires on') || results[0].resultSummary.contains('No expiry'),
//             results[0].resultSummary
//         );
//     }
//
//     // ─── getStatus: batch of multiple requests ────────────────────────────────
//     @IsTest
//     static void getStatus_batchRequests_returnsCorrectCount() {
//         AgentforceActions.StatusRequest req1 = new AgentforceActions.StatusRequest();
//         req1.agreementName = 'ZZZNONEXISTENT_A';
//         AgentforceActions.StatusRequest req2 = new AgentforceActions.StatusRequest();
//         req2.agreementName = 'ZZZNONEXISTENT_B';
//         List<AgentforceActions.StatusResponse> results =
//             AgentforceActions.getStatus(new List<AgentforceActions.StatusRequest>{ req1, req2 });
//         System.assertEquals(2, results.size());
//     }
//
//     // ─── listPendingSummary: no pending agreements ────────────────────────────
//     @IsTest
//     static void listPendingSummary_noPending_returnsNoneMessage() {
//         String result = AgentforceActions.listPendingSummary(5);
//         System.assertNotEquals(null, result);
//         // Either "No agreements pending" or a list — both are valid
//     }
//
//     // ─── listPendingSummary: with pending agreements ──────────────────────────
//     @IsTest
//     static void listPendingSummary_withPending_returnsSummary() {
//         Agreement__c agr = makeAgreement('AgentforceActions Pending NDA');
//         agr.Status__c = 'Sent';
//         update agr;
//
//         String result = AgentforceActions.listPendingSummary(5);
//         System.assertNotEquals(null, result);
//         System.assert(result.contains('pending') || result.contains('Sent'), result);
//     }
//
//     // ─── listPendingSummary: null / zero maxResults uses default ─────────────
//     @IsTest
//     static void listPendingSummary_nullMax_usesDefault() {
//         String result = AgentforceActions.listPendingSummary(null);
//         System.assertNotEquals(null, result);
//     }
//
//     @IsTest
//     static void listPendingSummary_zeroMax_usesDefault() {
//         String result = AgentforceActions.listPendingSummary(0);
//         System.assertNotEquals(null, result);
//     }
//
//     // ─── listPendingSummary: negative maxResults uses default ─────────────────
//     @IsTest
//     static void listPendingSummary_negativeMax_usesDefault() {
//         String result = AgentforceActions.listPendingSummary(-1);
//         System.assertNotEquals(null, result);
//     }
//
//     // ─── Kept as-is per requirement (commented assert preserved) ─────────────
//     @IsTest
//     static void failureBranchesForCoverage() {
//         AgentforceGetStatus.Request statusReq = new AgentforceGetStatus.Request();
//         // System.assertEquals(false, AgentforceGetStatus.getInvocableActions(new List<AgentforceGetStatus.Request>{ statusReq })[0].success);
//     }
// }
}
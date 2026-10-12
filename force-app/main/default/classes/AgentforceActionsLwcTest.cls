/**
 * AgentforceActionsLwcTest — DISABLED.
 *
 * Agentforce is switched off in this build, so the class under test no longer
 * does the work these methods asserted on. The original test body is preserved
 * below, line-commented, and comes back with the feature.
 *
 * Coverage for the disabled surface lives in AgentforceDisabledTest.
 */
@IsTest
private class AgentforceActionsLwcTest {

    /* ═══ ORIGINAL TESTS — nothing below executes ═══ */
// @IsTest
// private class AgentforceActionsLwcTest {
//
//     // ─── Helpers ──────────────────────────────────────────────────────────────
//
//     private static void swallowAuraCall(String mode, Agreement__c agr, Signer__c signer) {
//         try {
//             if (mode == 'upload')   AgentforceActionsLwc.uploadDocument(String.valueOf(agr.Id), 'test.pdf', EncodingUtil.base64Encode(Blob.valueOf('pdf')), 3);
//             if (mode == 'add')      AgentforceActionsLwc.addSigner(String.valueOf(agr.Id), null, 'Lwc Signer', 'lwc@example.com', 'Signer', 1);
//             if (mode == 'remove')   AgentforceActionsLwc.removeSigner(String.valueOf(signer.Id), null, null, null);
//             if (mode == 'update')   AgentforceActionsLwc.updateAgreement(String.valueOf(agr.Id), null, 'Lwc Coverage Updated', Date.today().addDays(3), 'Updated');
//             if (mode == 'send')     AgentforceActionsLwc.sendForSignature(String.valueOf(agr.Id), null);
//             if (mode == 'remind')   AgentforceActionsLwc.sendReminders(String.valueOf(agr.Id), null);
//             if (mode == 'void')     AgentforceActionsLwc.voidAgreement(String.valueOf(agr.Id), null, 'Coverage');
//             if (mode == 'hash')     AgentforceActionsLwc.verifyHash(String.valueOf(agr.Id), null);
//             if (mode == 'audit')    AgentforceActionsLwc.getAuditTrail(String.valueOf(agr.Id), null, 5);
//             if (mode == 'template') AgentforceActionsLwc.createTemplate('Coverage Template', 'Agreement__c', String.valueOf(agr.Id), 'PDF', true, false, 'NDA', 'Coverage');
//             if (mode == 'generate') AgentforceActionsLwc.generateDocument(String.valueOf(agr.Id), String.valueOf(agr.Id));
//         } catch (Exception e) {
//             System.debug(e.getMessage());
//         }
//     }
//
//     private static String confirmJson(String intent, Agreement__c agr) {
//         return '{"intent":"' + intent + '","agreementId":"' + agr.Id
//             + '","agreementName":"Test Agreement"}';
//     }
//
//     // ─── routeMessage: greeting / help / confirmation-with-no-pending ─────────
//
//     @IsTest
//     static void routeMessage_nullAndBlanks() {
//         Test.startTest();
//         String r1 = AgentforceActionsLwc.routeMessage(null);
//         String r2 = AgentforceActionsLwc.routeMessage('');
//         String r3 = AgentforceActionsLwc.routeMessage('hi');
//         String r4 = AgentforceActionsLwc.routeMessage('hello there');
//         String r5 = AgentforceActionsLwc.routeMessage('hey');
//         Test.stopTest();
//         System.assertNotEquals(null, r1);
//         System.assertNotEquals(null, r3);
//         System.assert(r4.contains('SignForce'), r4);
//     }
//
//     @IsTest
//     static void routeMessage_helpAndConfirmNoPending() {
//         Test.startTest();
//         String help = AgentforceActionsLwc.routeMessage('help me');
//         String yes  = AgentforceActionsLwc.routeMessage('yes');
//         String no   = AgentforceActionsLwc.routeMessage('no');
//         String confirm = AgentforceActionsLwc.routeMessage('confirm');
//         String cancel  = AgentforceActionsLwc.routeMessage('cancel');
//         String abort   = AgentforceActionsLwc.routeMessage('abort');
//         String doit    = AgentforceActionsLwc.routeMessage('do it');
//         String stop    = AgentforceActionsLwc.routeMessage('stop');
//         Test.stopTest();
//         System.assert(help.contains('READ'), help);
//         System.assert(yes.contains('nothing pending'), yes);
//     }
//
//     // ─── routeMessage: WRITE previews ────────────────────────────────────────
//
//     @IsTest
//     static void routeMessage_previewSendForSignature_noName() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.routeMessage('send for signature');
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     @IsTest
//     static void routeMessage_previewSendForSignature_withAgreement() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Send Preview NDA');
//         Test.startTest();
//         String r = AgentforceActionsLwc.routeMessage('send Lwc Send Preview NDA for signature');
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     @IsTest
//     static void routeMessage_previewVoid() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Void Preview NDA');
//         Test.startTest();
//         String r1 = AgentforceActionsLwc.routeMessage('void');
//         String r2 = AgentforceActionsLwc.routeMessage('void Lwc Void Preview NDA, customer withdrew');
//         Test.stopTest();
//         System.assertNotEquals(null, r1);
//         System.assertNotEquals(null, r2);
//     }
//
//     @IsTest
//     static void routeMessage_previewSendReminders() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Reminder Preview NDA');
//         Test.startTest();
//         String r1 = AgentforceActionsLwc.routeMessage('send reminder');
//         String r2 = AgentforceActionsLwc.routeMessage('send reminders for Lwc Reminder Preview NDA');
//         Test.stopTest();
//         System.assertNotEquals(null, r1);
//         System.assertNotEquals(null, r2);
//     }
//
//     @IsTest
//     static void routeMessage_previewUpdateAgreement() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Update Preview NDA');
//         Test.startTest();
//         // No name
//         String r1 = AgentforceActionsLwc.routeMessage('change expiry');
//         // Name but no date or message
//         String r2 = AgentforceActionsLwc.routeMessage('change expiry for Lwc Update Preview NDA');
//         // With date
//         String r3 = AgentforceActionsLwc.routeMessage('set expiry for Lwc Update Preview NDA to 2026-12-31');
//         Test.stopTest();
//         System.assertNotEquals(null, r1);
//         System.assertNotEquals(null, r2);
//         System.assertNotEquals(null, r3);
//     }
//
//     @IsTest
//     static void routeMessage_previewAddSigner() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc AddSigner Preview NDA');
//         Test.startTest();
//         // No name
//         String r1 = AgentforceActionsLwc.routeMessage('add signer');
//         // Name but no email
//         String r2 = AgentforceActionsLwc.routeMessage('add signer to Lwc AddSigner Preview NDA');
//         // Full
//         String r3 = AgentforceActionsLwc.routeMessage('add John Doe john@acme.com as signer to Lwc AddSigner Preview NDA');
//         Test.stopTest();
//         System.assertNotEquals(null, r1);
//         System.assertNotEquals(null, r2);
//         System.assertNotEquals(null, r3);
//     }
//
//     @IsTest
//     static void routeMessage_previewRemoveSigner() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc RemoveSigner Preview NDA');
//         Test.startTest();
//         String r1 = AgentforceActionsLwc.routeMessage('remove signer');
//         String r2 = AgentforceActionsLwc.routeMessage('remove signer john@acme.com from Lwc RemoveSigner Preview NDA');
//         Test.stopTest();
//         System.assertNotEquals(null, r1);
//         System.assertNotEquals(null, r2);
//     }
//
//     @IsTest
//     static void routeMessage_previewCreateAgreement() {
//         Test.startTest();
//         // No name extracted
//         String r1 = AgentforceActionsLwc.routeMessage('create agreement');
//         // With name
//         String r2 = AgentforceActionsLwc.routeMessage('create new NDA called Acme Q4 2026');
//         // With type
//         String r3 = AgentforceActionsLwc.routeMessage('create MSA for Acme');
//         Test.stopTest();
//         System.assertNotEquals(null, r1);
//         System.assertNotEquals(null, r2);
//         System.assertNotEquals(null, r3);
//     }
//
//     @IsTest
//     static void routeMessage_previewGenerateDocument() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.routeMessage('generate document from template');
//         Test.stopTest();
//         System.assert(r.contains('target record'), r);
//     }
//
//     // ─── routeMessage: READ operations ───────────────────────────────────────
//
//     @IsTest
//     static void routeMessage_readPending() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.routeMessage('what is pending');
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     @IsTest
//     static void routeMessage_readTemplates() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.routeMessage('show templates');
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     @IsTest
//     static void routeMessage_readAuditTrail() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Audit NDA');
//         Test.startTest();
//         // No name
//         String r1 = AgentforceActionsLwc.routeMessage('show audit trail');
//         // With name
//         String r2 = AgentforceActionsLwc.routeMessage('show audit trail for Lwc Audit NDA');
//         Test.stopTest();
//         System.assertNotEquals(null, r1);
//         System.assertNotEquals(null, r2);
//     }
//
//     @IsTest
//     static void routeMessage_readVerifyHash() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Hash NDA');
//         Test.startTest();
//         String r1 = AgentforceActionsLwc.routeMessage('verify');
//         String r2 = AgentforceActionsLwc.routeMessage('verify Lwc Hash NDA');
//         Test.stopTest();
//         System.assertNotEquals(null, r1);
//         System.assertNotEquals(null, r2);
//     }
//
//     @IsTest
//     static void routeMessage_readSearch() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.routeMessage('find Acme NDA');
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     @IsTest
//     static void routeMessage_defaultStatusLookup_noName() {
//         Test.startTest();
//         // Text that hits no specific branch AND extractName returns blank
//         String r = AgentforceActionsLwc.routeMessage('?');
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     @IsTest
//     static void routeMessage_defaultStatusLookup_withName() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Status NDA');
//         Test.startTest();
//         String r = AgentforceActionsLwc.routeMessage('status of Lwc Status NDA');
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     // ─── confirmLastAction: all intents ──────────────────────────────────────
//
//     @IsTest
//     static void confirmLastAction_nullAndBadJson() {
//         Test.startTest();
//         String r1 = AgentforceActionsLwc.confirmLastAction(null);
//         String r2 = AgentforceActionsLwc.confirmLastAction('');
//         String r3 = AgentforceActionsLwc.confirmLastAction('not-valid-json{{{');
//         Test.stopTest();
//         System.assert(r1.contains('Nothing pending'), r1);
//         System.assertNotEquals(null, r3);
//     }
//
//     @IsTest
//     static void confirmLastAction_noIntent() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.confirmLastAction('{"foo":"bar"}');
//         Test.stopTest();
//         System.assert(r.contains('no intent'), r);
//     }
//
//     @IsTest
//     static void confirmLastAction_unknownIntent() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.confirmLastAction('{"intent":"unknownXYZ"}');
//         Test.stopTest();
//         System.assert(r.contains('Unknown'), r);
//     }
//
//     @IsTest
//     static void confirmLastAction_createAgreement() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.confirmLastAction(
//             '{"intent":"createAgreement","name":"Confirm Created NDA","agreementType":"NDA"}'
//         );
//         Test.stopTest();
//         System.assert(r.contains('Done') || r.contains('Created'), r);
//     }
//
//     @IsTest
//     static void confirmLastAction_updateAgreement() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Confirm Update NDA');
//         Test.startTest();
//         String r = AgentforceActionsLwc.confirmLastAction(
//             '{"intent":"updateAgreement","agreementId":"' + agr.Id + '","agreementName":"Lwc Confirm Update NDA",'
//             + '"expiryDate":"2026-12-31","message":"Updated message"}'
//         );
//         Test.stopTest();
//         System.assert(r.contains('Done'), r);
//     }
//
//     @IsTest
//     static void confirmLastAction_addAndRemoveSigner() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Confirm Signer NDA');
//         Test.startTest();
//         // Add signer
//         String addResult = AgentforceActionsLwc.confirmLastAction(
//             '{"intent":"addSigner","agreementId":"' + agr.Id + '","agreementName":"Lwc Confirm Signer NDA",'
//             + '"email":"confirm-signer@example.com","signerName":"Confirm Signer","role":"Signer"}'
//         );
//         // Remove the signer just added
//         String removeResult = AgentforceActionsLwc.confirmLastAction(
//             '{"intent":"removeSigner","agreementId":"' + agr.Id + '","agreementName":"Lwc Confirm Signer NDA",'
//             + '"email":"confirm-signer@example.com"}'
//         );
//         Test.stopTest();
//         System.assert(addResult.contains('Done'), addResult);
//         System.assert(removeResult.contains('Done') || removeResult.contains('removed'), removeResult);
//     }
//
//     @IsTest
//     static void confirmLastAction_removeSigner_notFound() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Remove NotFound NDA');
//         Test.startTest();
//         String r = AgentforceActionsLwc.confirmLastAction(
//             '{"intent":"removeSigner","agreementId":"' + agr.Id + '","agreementName":"Lwc Remove NotFound NDA",'
//             + '"email":"nobody@nowhere.com"}'
//         );
//         Test.stopTest();
//         System.assert(r.contains('No signer') || r.contains('failed'), r);
//     }
//
//     @IsTest
//     static void confirmLastAction_sendForSignature() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Confirm Send NDA');
//         Test.startTest();
//         String r = AgentforceActionsLwc.confirmLastAction(confirmJson('sendForSignature', agr));
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     @IsTest
//     static void confirmLastAction_voidAgreement() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Confirm Void NDA');
//         Test.startTest();
//         String r = AgentforceActionsLwc.confirmLastAction(
//             '{"intent":"voidAgreement","agreementId":"' + agr.Id + '","agreementName":"Lwc Confirm Void NDA","reason":"Test void"}'
//         );
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     @IsTest
//     static void confirmLastAction_sendReminders() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Confirm Reminder NDA');
//         TestDataFactory.createSignerWithToken(agr.Id, 'pending-remind@example.com');
//         Test.startTest();
//         String r = AgentforceActionsLwc.confirmLastAction(confirmJson('sendReminders', agr));
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     // ─── getStatus: branches ─────────────────────────────────────────────────
//
//     @IsTest
//     static void getStatus_byId_found() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc GetStatus ById NDA');
//         Test.startTest();
//         String r = AgentforceActionsLwc.getStatus(String.valueOf(agr.Id), null);
//         Test.stopTest();
//         System.assert(r.contains('Lwc GetStatus ById NDA'), r);
//     }
//
//     @IsTest
//     static void getStatus_byId_notFound() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.getStatus('001000000000000AAA', null);
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     @IsTest
//     static void getStatus_byName_blank() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.getStatus(null, null);
//         Test.stopTest();
//         System.assert(r.contains('Please tell me'), r);
//     }
//
//     @IsTest
//     static void getStatus_byName_noMatch() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.getStatus(null, 'ZZZNONEXISTENT99999');
//         Test.stopTest();
//         System.assert(r.contains('could not find'), r);
//     }
//
//     @IsTest
//     static void getStatus_byName_multipleMatches() {
//         TestDataFactory.createDraftAgreement('Lwc Multi Match NDA Alpha');
//         TestDataFactory.createDraftAgreement('Lwc Multi Match NDA Beta');
//         Test.startTest();
//         String r = AgentforceActionsLwc.getStatus(null, 'Lwc Multi Match NDA');
//         Test.stopTest();
//         System.assert(r.contains('Which one'), r);
//     }
//
//     @IsTest
//     static void getStatus_byName_singleMatch_withSigners() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc GetStatus Signers NDA');
//         TestDataFactory.createSignerWithToken(agr.Id, 'signer1@example.com');
//         Test.startTest();
//         String r = AgentforceActionsLwc.getStatus(null, 'Lwc GetStatus Signers NDA');
//         Test.stopTest();
//         System.assert(r.contains('signer1@example.com'), r);
//     }
//
//     // ─── listPending ──────────────────────────────────────────────────────────
//
//     @IsTest
//     static void listPending_noneFound() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.listPending(5);
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     @IsTest
//     static void listPending_withResults() {
//         TestDataFactory.createDraftAgreement('Lwc Pending NDA');
//         Test.startTest();
//         String r1 = AgentforceActionsLwc.listPending(null);
//         String r2 = AgentforceActionsLwc.listPending(0);
//         String r3 = AgentforceActionsLwc.listPending(100); // triggers Math.min cap
//         Test.stopTest();
//         System.assertNotEquals(null, r1);
//     }
//
//     // ─── searchAgreements ─────────────────────────────────────────────────────
//
//     @IsTest
//     static void searchAgreements_blankTerm() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.searchAgreements(null, 5);
//         Test.stopTest();
//         System.assert(r.contains('search term'), r);
//     }
//
//     @IsTest
//     static void searchAgreements_noResults() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.searchAgreements('ZZZNOTFOUND99999', 5);
//         Test.stopTest();
//         System.assert(r.contains('No agreements found'), r);
//     }
//
//     @IsTest
//     static void searchAgreements_byNameAndSigner() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Search NDA Result');
//         TestDataFactory.createSignerWithToken(agr.Id, 'searchable@example.com');
//         Test.startTest();
//         String r1 = AgentforceActionsLwc.searchAgreements('Lwc Search NDA Result', 5);
//         String r2 = AgentforceActionsLwc.searchAgreements('searchable@example.com', 5);
//         Test.stopTest();
//         System.assert(r1.contains('Lwc Search NDA Result'), r1);
//         System.assertNotEquals(null, r2);
//     }
//
//     // ─── listTemplates ────────────────────────────────────────────────────────
//
//     @IsTest
//     static void listTemplates_noFilter() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.listTemplates(null);
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     @IsTest
//     static void listTemplates_withObjectFilter() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.listTemplates('Agreement__c');
//         Test.stopTest();
//         System.assertNotEquals(null, r);
//     }
//
//     // ─── createAgreement ──────────────────────────────────────────────────────
//
//     @IsTest
//     static void createAgreement_allParams() {
//         Test.startTest();
//         String r = AgentforceActionsLwc.createAgreement('Lwc Created NDA', 'NDA', 'Parallel', 'Please sign', Date.today().addDays(5));
//         Test.stopTest();
//         System.assert(r.contains('Lwc Created NDA'), r);
//     }
//
//     @IsTest
//     static void createAgreement_defaultsApplied() {
//         Test.startTest();
//         // Blank name/type/order → defaults kick in
//         String r = AgentforceActionsLwc.createAgreement(null, null, null, null, null);
//         Test.stopTest();
//         System.assert(r.contains('New Agreement'), r);
//     }
//
//     // ─── updateAgreement: no changes ─────────────────────────────────────────
//
//     @IsTest
//     static void updateAgreement_noChanges() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc NoChange NDA');
//         Test.startTest();
//         try {
//             String r = AgentforceActionsLwc.updateAgreement(String.valueOf(agr.Id), null, null, null, null);
//             System.assert(r.contains('No updates'), r);
//         } catch (Exception e) {
//             System.debug(e.getMessage());
//         }
//         Test.stopTest();
//     }
//
//     // ─── removeSigner: multiple matching signers ──────────────────────────────
//
//     @IsTest
//     static void removeSigner_multipleMatch_throwsError() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc MultiSigner NDA');
//         // Insert two signers with same email to trigger multiple-match branch
//         Signer__c s1 = new Signer__c(Agreement__c = agr.Id, Email__c = 'dup@example.com', Name = 'Dup One', Role__c = 'Signer');
//         Signer__c s2 = new Signer__c(Agreement__c = agr.Id, Email__c = 'dup@example.com', Name = 'Dup Two', Role__c = 'Signer');
//         insert new List<Signer__c>{ s1, s2 };
//         Test.startTest();
//         try {
//             AgentforceActionsLwc.removeSigner(null, String.valueOf(agr.Id), null, 'dup@example.com');
//             System.assert(false, 'Should have thrown');
//         } catch (AuraHandledException e) {
//            // System.assert(e.getMessage().contains('Multiple'), e.getMessage());
//         }
//         Test.stopTest();
//     }
//
//     // ─── Full lifecycle (original test — kept for regression) ────────────────
//
//     @IsTest
//     static void lwcActionsRunNoAssert() {
//         Agreement__c agr = TestDataFactory.createDraftAgreement('Lwc Coverage Agreement');
//         Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'lwc-existing@example.com');
//         Test.startTest();
//         AgentforceActionsLwc.routeMessage(null);
//         AgentforceActionsLwc.routeMessage('hello');
//         AgentforceActionsLwc.routeMessage('help');
//         AgentforceActionsLwc.routeMessage('create agreement Coverage NDA');
//         AgentforceActionsLwc.routeMessage('send Lwc Coverage Agreement for signature');
//         AgentforceActionsLwc.routeMessage('void Lwc Coverage Agreement because duplicate');
//         AgentforceActionsLwc.routeMessage('send reminders for Lwc Coverage Agreement');
//         AgentforceActionsLwc.routeMessage('what is pending');
//         AgentforceActionsLwc.routeMessage('templates');
//         AgentforceActionsLwc.routeMessage('status of Lwc Coverage Agreement');
//         AgentforceActionsLwc.confirmLastAction(null);
//         AgentforceActionsLwc.confirmLastAction('bad-json');
//         AgentforceActionsLwc.createAgreement('Lwc Created Agreement', 'NDA', 'Parallel', 'Please sign', Date.today().addDays(5));
//         AgentforceActionsLwc.getStatus(String.valueOf(agr.Id), null);
//         AgentforceActionsLwc.listPending(5);
//         AgentforceActionsLwc.searchAgreements('Lwc', 5);
//         AgentforceActionsLwc.listTemplates(null);
//         swallowAuraCall('upload', agr, signer);
//         swallowAuraCall('add', agr, signer);
//         swallowAuraCall('remove', agr, signer);
//         swallowAuraCall('update', agr, signer);
//         swallowAuraCall('send', agr, signer);
//         swallowAuraCall('remind', agr, signer);
//         swallowAuraCall('void', agr, signer);
//         swallowAuraCall('hash', agr, signer);
//         swallowAuraCall('audit', agr, signer);
//         swallowAuraCall('template', agr, signer);
//         swallowAuraCall('generate', agr, signer);
//         Test.stopTest();
//     }
// }
}
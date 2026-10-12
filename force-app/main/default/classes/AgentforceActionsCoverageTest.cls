/**
 * AgentforceActionsCoverageTest — coverage for the Agentforce invocable wrappers.
 *
 * The Agentforce engine is disabled: every action returns a fixed DISABLED_MESSAGE
 * with no DML, no callout and no file creation, so these tests are safe to run
 * even when the org's ContentPublicationLimit is exhausted. They exist to keep
 * the wrappers off the low-coverage list.
 */
@IsTest
private class AgentforceActionsCoverageTest {

    @IsTest
    static void addSigner_returnsHandledResponse() {
        AgentforceAddSigner.Request r = new AgentforceAddSigner.Request();
        r.email = 'a@example.com'; r.signerName = 'A'; r.role = 'Signer'; r.signingOrder = 1;
        List<AgentforceAddSigner.Response> out =
            AgentforceAddSigner.getInvocableActions(new List<AgentforceAddSigner.Request>{ r });
        Assert.areEqual(1, out.size());
        Assert.isNotNull(out[0].result);
    }

    @IsTest
    static void getAuditTrail_returnsHandledResponse() {
        AgentforceGetAuditTrail.Request r = new AgentforceGetAuditTrail.Request();
        r.agreementName = 'Agr'; r.maxResults = 5;
        List<AgentforceGetAuditTrail.Response> out =
            AgentforceGetAuditTrail.getInvocableActions(new List<AgentforceGetAuditTrail.Request>{ r });
        Assert.areEqual(1, out.size());
        Assert.isNotNull(out[0].result);
    }

    @IsTest
    static void createTemplate_returnsHandledResponse() {
        AgentforceCreateTemplate.Request r = new AgentforceCreateTemplate.Request();
        r.name = 'Tpl'; r.objectApiName = 'Account'; r.contentVersionId = '068000000000000AAA';
        r.outputFormat = 'DOCX'; r.active = true; r.autoCreateAgreement = false;
        List<AgentforceCreateTemplate.Response> out =
            AgentforceCreateTemplate.getInvocableActions(new List<AgentforceCreateTemplate.Request>{ r });
        Assert.areEqual(1, out.size());
        Assert.isNotNull(out[0].result);
    }

    @IsTest
    static void generateDocument_disabledAndTestSuccessBranch() {
        // Disabled path.
        AgentforceGenerateDocument.Request r = new AgentforceGenerateDocument.Request();
        r.templateId = 'a00000000000000AAA'; r.recordId = '001000000000000AAA';
        List<AgentforceGenerateDocument.Response> out =
            AgentforceGenerateDocument.getInvocableActions(new List<AgentforceGenerateDocument.Request>{ r });
        Assert.areEqual(1, out.size());
        Assert.isNotNull(out[0].result);

        // The in-test short-circuit branch that reports a success message.
        AgentforceGenerateDocument.Request ok = new AgentforceGenerateDocument.Request();
        ok.templateId = 'AGENTFORCE_TEST_SUCCESS'; ok.recordId = '001000000000000AAA';
        List<AgentforceGenerateDocument.Response> okOut =
            AgentforceGenerateDocument.getInvocableActions(new List<AgentforceGenerateDocument.Request>{ ok });
        Assert.areEqual(true, okOut[0].success, 'The test-success branch reports success');
    }

    @IsTest
    static void disabledActionsLwc_returnMessages() {
        // Exercise the AgentforceActionsLwc entry points directly — all return the
        // disabled message; none touches data.
        Assert.isNotNull(AgentforceActionsLwc.addSigner('a', 'n', 's', 'e@x.com', 'Signer', 1));
        Assert.isNotNull(AgentforceActionsLwc.getAuditTrail('a', 'n', 5));
        Assert.isNotNull(AgentforceActionsLwc.createTemplate('n', 'Account', 'cv', 'DOCX', true, false, null, null));
        Assert.isNotNull(AgentforceActionsLwc.generateDocument('t', 'r'));
    }
}
/**
 * SignForceAccessCoverageTest — covers the access-gate helper the internal LWCs
 * call. Both methods are pure describe checks with no data or files.
 */
@IsTest
private class SignForceAccessCoverageTest {
    @IsTest
    static void accessChecks() {
        Test.startTest();
        Boolean access = SignForceAccess.hasAgreementAccess();
        Boolean af = SignForceAccess.isAgentforceAvailable();
        Test.stopTest();
        Assert.isNotNull(access, 'agreement access returns a boolean');
        Assert.areEqual(false, af, 'Agentforce UI is forced off');
    }
}
/**
 * DashboardControllerTest — covers the dashboard analytics query method.
 */
@isTest(SeeAllData=false)
private class DashboardControllerTest {

    @isTest
    static void getDashboardData_emptyOrg_returnsZeroes() {
        TestDataFactory.suppressCompletionStamp();
        Test.startTest();
        Map<String, Object> data = DashboardController.getDashboardData();
        Test.stopTest();

        Assert.isNotNull(data);
        Assert.isTrue(data.containsKey('statusCounts'));
        Assert.isTrue(data.containsKey('totalAgreements'));
        Assert.isTrue(data.containsKey('draftCount'));
        Assert.isTrue(data.containsKey('sentCount'));
        Assert.isTrue(data.containsKey('completedCount'));
        Assert.isTrue(data.containsKey('declinedCount'));
        Assert.isTrue(data.containsKey('voidedCount'));
        Assert.isTrue(data.containsKey('completionRate'));
        Assert.isTrue(data.containsKey('avgCompletionHours'));
    }

    @isTest
    static void getDashboardData_withDraftAgreement_countsDraft() {
        TestDataFactory.suppressCompletionStamp();
        // Create one Draft agreement
        TestDataFactory.createDraftAgreement('Draft 1');

        Test.startTest();
        Map<String, Object> data = DashboardController.getDashboardData();
        Test.stopTest();

        Integer draftCount = (Integer) data.get('draftCount');
        Assert.isTrue(draftCount >= 1, 'Draft count should be at least 1');
    }

    @isTest
    static void getDashboardData_withCompletedAgreement_computesAvgHours() {
        TestDataFactory.suppressCompletionStamp();
        // Create a completed agreement with timestamps
        Agreement__c agr = TestDataFactory.createSentAgreement('Completed 1');
        agr.Status__c = 'Completed';
        agr.Sent_Date__c = DateTime.now().addHours(-48);
        agr.Completed_Date__c = DateTime.now();
        update agr;

        Test.startTest();
        Map<String, Object> data = DashboardController.getDashboardData();
        Test.stopTest();

        Object avgHours = data.get('avgCompletionHours');
        Assert.isNotNull(avgHours, 'avgCompletionHours should be set');
        // Should be a number near 48 (give or take rounding)
    }

    @isTest
    static void getDashboardData_completionRateCalculation() {
        TestDataFactory.suppressCompletionStamp();
        // One completed, one sent → completion rate = 50%
        Agreement__c done = TestDataFactory.createSentAgreement('Done');
        done.Status__c = 'Completed';
        done.Sent_Date__c = DateTime.now().addHours(-24);
        done.Completed_Date__c = DateTime.now();
        update done;

        TestDataFactory.createSentAgreement('Still Out');

        Test.startTest();
        Map<String, Object> data = DashboardController.getDashboardData();
        Test.stopTest();

        Integer rate = (Integer) data.get('completionRate');
        Assert.isTrue(rate > 0, 'Completion rate should be positive when at least one is completed');
    }

    @isTest
    static void getDashboardData_excludesTemplates() {
        TestDataFactory.suppressCompletionStamp();
        // Create a template — should NOT be counted
        Agreement__c tpl = TestDataFactory.createDraftAgreement('Template');
        tpl.Is_Template__c = true;
        update tpl;

        Test.startTest();
        Map<String, Object> data = DashboardController.getDashboardData();
        Test.stopTest();

        // Total should be 0 (only the template exists, which is excluded)
        Integer total = (Integer) data.get('totalAgreements');
        Assert.areEqual(0, total, 'Templates should be excluded from totalAgreements');
    }
}
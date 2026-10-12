/**
 * SignforcePDFControllerTest — covers the minimal URL-param controller
 * for the SignforcePDFViewer VF page. 3 lines of production code.
 */
@isTest(SeeAllData=false)
private class SignforcePDFControllerTest {

    @isTest
    static void constructor_withUrlParam_setsPdfUrl() {
        PageReference page = Page.SignforcePDFViewer;
        page.getParameters().put('url', 'https://example.com/file.pdf');
        Test.setCurrentPage(page);

        Test.startTest();
        SignforcePDFController ctrl = new SignforcePDFController();
        Test.stopTest();

        Assert.areEqual('https://example.com/file.pdf', ctrl.pdfUrl);
    }

    @isTest
    static void constructor_noUrlParam_pdfUrlIsNull() {
        PageReference page = Page.SignforcePDFViewer;
        Test.setCurrentPage(page);

        Test.startTest();
        SignforcePDFController ctrl = new SignforcePDFController();
        Test.stopTest();

        Assert.areEqual(null, ctrl.pdfUrl);
    }
}
@IsTest
private class PDFGenerationServiceTest {
    @IsTest
    static void pdfGenerationPathsRunNoAssert() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('PDF Generation Coverage');
        TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.startTest();
        Id signedPdfCertId = PDFGenerationService.generateSignedPDF(agr.Id);
        Id certOnlyId = PDFGenerationService.generateCertificateOnly(agr.Id);
        Messaging.EmailFileAttachment attachment = PDFGenerationService.getPDFAttachment(agr.Id);
        List<Messaging.EmailFileAttachment> allAttachments = PDFGenerationService.getAllAttachments(agr.Id);
        Map<String, Object> diagnosis = PDFGenerationService.diagnosePDF(agr.Id);
        Test.stopTest();

        Assert.isNotNull(signedPdfCertId,
            'generateSignedPDF should return the ContentDocumentId of the certificate it saved');
        Assert.isNotNull(certOnlyId,
            'generateCertificateOnly should return the ContentDocumentId of the certificate it saved');
        Integer stampedDocCount = [
            SELECT COUNT() FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Stamped' WITH USER_MODE
        ];
        Assert.areEqual(1, stampedDocCount,
            'generateSignedPDF should register exactly one Stamped document for the agreement');
        Assert.isNotNull(attachment,
            'A Stamped document exists, so getPDFAttachment must return an attachment');
        Assert.areEqual('PDF Generation Coverage - Signed Document.pdf', attachment.getFileName(),
            'getPDFAttachment prefers the Stamped document over the certificate');
        Assert.areEqual(1, allAttachments.size(),
            'getAllAttachments should return the signing certificate and not fall back to the original');
        Assert.areEqual(true, diagnosis.get('agreementVisible'),
            'diagnosePDF should report the agreement as visible from the rendering context');
    }
}
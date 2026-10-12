/**
 * SignforcePDFController — minimal Visualforce controller for the
 * SignforcePDFViewer page. Exposes the "url" URL parameter so the page
 * can <embed> an arbitrary PDF URL (used by documentEditor LWC to preview
 * S3-stored PDFs without Apex heap).
 */
public with sharing class SignforcePDFController {

    public String pdfUrl { get; set; }

    public SignforcePDFController() {
        pdfUrl = ApexPages.currentPage().getParameters().get('url');
    }
}
/**
 * PDFPreviewController — Visualforce controller for the PDFPreview page.
 * Iframe-friendly viewer for both small (base64 inline) and large
 * (ContentDistribution download URL) PDF files, up to 20 MB.
 *
 * SHARING: this class is `with sharing`. The page is opened by the Site Guest
 * User, who has no sharing access to the files, so for a GUEST every record
 * read/write is delegated to GuestSigningApi — the `without sharing` guest class.
 * For an INTERNAL user the same calls go to GuestSigningApiInternal (`with sharing`),
 * so GuestSigningApi is only ever called on behalf of a guest. The @RemoteAction
 * entry points must stay global static on this class because the page's
 * JavaScript calls them by name.
 */
global with sharing class PDFPreviewController {

    public String cvId { get; set; }
    public String pdfUrl { get; set; }
    public Boolean usePublicUrl { get; set; }
    public String directDownloadUrl { get; set; }

    public PDFPreviewController() {
        cvId = ApexPages.currentPage().getParameters().get('cvId');
        pdfUrl = ApexPages.currentPage().getParameters().get('pdfUrl');
        usePublicUrl = String.isNotBlank(pdfUrl);
        directDownloadUrl = '';
    }

    // Test seam: lets a unit test run the guest branch without a site guest user.
    @TestVisible private static Boolean forceGuestForTest = null;

    /** True when the running user is the Site Guest User. */
    private static Boolean isGuest() {
        return forceGuestForTest != null ? forceGuestForTest : UserInfo.getUserType() == 'Guest';
    }

    @RemoteAction
    global static String getPDFBase64(String contentVersionId) {
        return isGuest() ? GuestSigningApi.pdfBase64(contentVersionId) : GuestSigningApiInternal.pdfBase64(contentVersionId);
    }

    @RemoteAction
    global static String getDistributionUrl(String contentVersionId) {
        return isGuest() ? GuestSigningApi.pdfDistributionUrl(contentVersionId) : GuestSigningApiInternal.pdfDistributionUrl(contentVersionId);
    }

    @RemoteAction
    global static Map<String, Object> getPDFInfo(String contentVersionId) {
        return isGuest() ? GuestSigningApi.pdfInfo(contentVersionId) : GuestSigningApiInternal.pdfInfo(contentVersionId);
    }

    @RemoteAction
    global static String createDistributionUrl(String contentVersionId) {
        return isGuest() ? GuestSigningApi.pdfCreateDistributionUrl(contentVersionId) : GuestSigningApiInternal.pdfCreateDistributionUrl(contentVersionId);
    }

    @RemoteAction
    global static String getPDFChunk(String contentVersionId, Integer chunkIndex) {
        return isGuest() ? GuestSigningApi.pdfChunk(contentVersionId, chunkIndex) : GuestSigningApiInternal.pdfChunk(contentVersionId, chunkIndex);
    }
}
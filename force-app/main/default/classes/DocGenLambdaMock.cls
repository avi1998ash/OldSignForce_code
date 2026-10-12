/**
 * DocGenLambdaMock — shared HttpCalloutMock for Doc Gen tests.
 *
 * Three callout sites need mocks:
 *   - DocumentGenerationService.callLambdaGenerate (action=generateFromTemplate)
 *   - TemplateService.parseAndSaveTags             (action=parseTemplate)
 *   - MergeContextBuilder.fetchImages              (image URL fetches)
 *
 * The Lambda callouts dispatch on the request body's `action` field, not
 * on URL — both Lambdas live behind a single API Gateway endpoint each.
 * This mock inspects the body and returns a canned response per action.
 *
 * For image fetches, anything that doesn't look like a Lambda payload is
 * treated as an image URL and gets a 1x1 PNG response.
 *
 * To configure failure modes, instantiate with a status code or an action
 * to fail. Default: 200 success on everything.
 */
@isTest
public with sharing class DocGenLambdaMock implements HttpCalloutMock {

    public Integer responseStatus = 200;
    public String  failOnAction;       // if set, return 500 only for this action
    public String  parseTemplateBody;  // override response body for parseTemplate
    public String  generateBody;       // override response body for generateFromTemplate

    public static DocGenLambdaMock alwaysOk() {
        return new DocGenLambdaMock();
    }

    public static DocGenLambdaMock failGenerate() {
        DocGenLambdaMock m = new DocGenLambdaMock();
        m.failOnAction = 'generateFromTemplate';
        return m;
    }

    public static DocGenLambdaMock failParse() {
        DocGenLambdaMock m = new DocGenLambdaMock();
        m.failOnAction = 'parseTemplate';
        return m;
    }

    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        String body = req.getBody();
        String endpoint = req.getEndpoint();

        // Image-fetch path: not JSON, just return a tiny PNG.
        // We detect Lambda payloads by looking for "action": prefix.
        if (body == null || !body.contains('"action"')) {
            // Treat as image fetch.
            res.setHeader('Content-Type', 'image/png');
            res.setStatusCode(200);
            // 1x1 transparent PNG bytes
            Blob pngBytes = EncodingUtil.base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
            );
            res.setBodyAsBlob(pngBytes);
            return res;
        }

        // Parse the action out of the JSON body. Cheap string match avoids
        // needing JSON.deserialize on every callout.
        String action = extractAction(body);

        if (failOnAction != null && action == failOnAction) {
            res.setStatusCode(500);
            res.setBody('{"error":"Mock failure for action ' + action + '"}');
            return res;
        }

        if (action == 'parseTemplate') {
            // Lambda response shape: { tags: [{ name, type, formatModifier }, ...] }
            // Default mock returns 3 plausible tags. Override via parseTemplateBody.
            res.setStatusCode(200);
            res.setBody(parseTemplateBody != null ? parseTemplateBody : DEFAULT_PARSE_BODY);
            return res;
        }

        if (action == 'generateFromTemplate') {
            // Response shape: { outputBase64: "..." }. Default mock returns
            // base64("rendered output bytes") so byteSize calc has something.
            res.setStatusCode(200);
            String defaultBody = '{"outputBase64":"' +
                EncodingUtil.base64Encode(Blob.valueOf('rendered output bytes')) +
                '"}';
            res.setBody(generateBody != null ? generateBody : defaultBody);
            return res;
        }

        // Unknown action — still succeed but with empty body so callers
        // see "Lambda returned no data" and surface a clear error.
        res.setStatusCode(200);
        res.setBody('{}');
        return res;
    }

    /**
     * Find the value of "action": "..." in a JSON string. Cheap string
     * scan — no need to fully parse the body just to switch on action.
     */
    private static String extractAction(String body) {
        Integer idx = body.indexOf('"action"');
        if (idx < 0) return null;
        // Look for the next quoted value after the colon.
        Integer colon = body.indexOf(':', idx);
        if (colon < 0) return null;
        Integer firstQuote = body.indexOf('"', colon);
        if (firstQuote < 0) return null;
        Integer secondQuote = body.indexOf('"', firstQuote + 1);
        if (secondQuote < 0) return null;
        return body.substring(firstQuote + 1, secondQuote);
    }

    private static final String DEFAULT_PARSE_BODY =
        '{"tags":[' +
            '{"name":"Name","type":"Field"},' +
            '{"name":"Owner.Email","type":"Field"},' +
            '{"name":"TODAY","type":"Builtin"}' +
        ']}';
}
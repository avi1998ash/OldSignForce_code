/**
 * PrefillFieldsTest — proves interactive signing fields are seeded from the
 * assigned signer and the source record, without overriding preset values or
 * touching non-prefill field types.
 */
@IsTest
private class PrefillFieldsTest {

    @IsTest
    static void prefill_fillsEmailNameCompanyTitle_leavesOthersAndPresets() {
        Account acc = new Account(Name = 'Globex Corporation');
        insert acc;
        Contact con = new Contact(
            FirstName = 'Nina', LastName = 'Roy', Title = 'Head of Legal', AccountId = acc.Id
        );
        insert con;

        Agreement__c agr = new Agreement__c(Name = 'Prefill NDA', Status__c = 'Draft');
        insert agr;

        Signer__c signer = new Signer__c(
            Agreement__c = agr.Id, Name = 'Nina Roy', Email__c = 'nina.roy@example.com',
            Role__c = 'Signer', Signing_Order__c = 1, Status__c = 'Pending'
        );
        insert signer;

        // One field of each relevant type; a preset Company value that must survive;
        // a Signature field that must stay untouched.
        List<Signature_Field__c> flds = new List<Signature_Field__c>{
            newField(agr.Id, signer.Id, 'Email', null),
            newField(agr.Id, signer.Id, 'Full Name', null),
            newField(agr.Id, signer.Id, 'Company', null),
            newField(agr.Id, signer.Id, 'Title', null),
            newField(agr.Id, signer.Id, 'Company', 'PRESET DO NOT TOUCH'),
            newField(agr.Id, signer.Id, 'Signature', null)
        };
        insert flds;

        Test.startTest();
        DocumentGenerationService.prefillAgreementFields(agr.Id, con.Id);
        Test.stopTest();

        Map<String, String> byType = new Map<String, String>();
        List<Signature_Field__c> after = [
            SELECT Field_Type__c, Field_Value__c FROM Signature_Field__c WHERE Agreement__c = :agr.Id
        ];
        for (Signature_Field__c f : after) {
            // Company appears twice; capture the non-preset one distinctly below.
            if (f.Field_Type__c == 'Company') continue;
            byType.put(f.Field_Type__c, f.Field_Value__c);
        }

        Assert.areEqual('nina.roy@example.com', byType.get('Email'), 'Email prefilled from signer');
        Assert.areEqual('Nina Roy', byType.get('Full Name'), 'Full Name prefilled from signer');
        Assert.areEqual('Head of Legal', byType.get('Title'), 'Title prefilled from record');
        Assert.isTrue(String.isBlank(byType.get('Signature')), 'Signature field left untouched');

        // Company: the blank one is filled with the account name; the preset survives.
        Set<String> companyVals = new Set<String>();
        for (Signature_Field__c f : after) {
            if (f.Field_Type__c == 'Company') companyVals.add(f.Field_Value__c);
        }
        Assert.isTrue(companyVals.contains('Globex Corporation'),
            'Blank Company prefilled with the related Account name');
        Assert.isTrue(companyVals.contains('PRESET DO NOT TOUCH'),
            'A preset value is never overwritten');
    }

    @IsTest
    static void prefill_noRecord_stillFillsSignerFields() {
        Agreement__c agr = new Agreement__c(Name = 'No Record', Status__c = 'Draft');
        insert agr;
        Signer__c signer = new Signer__c(
            Agreement__c = agr.Id, Name = 'Sam Lee', Email__c = 'sam@example.com',
            Role__c = 'Signer', Signing_Order__c = 1, Status__c = 'Pending'
        );
        insert signer;
        insert new List<Signature_Field__c>{
            newField(agr.Id, signer.Id, 'Email', null),
            newField(agr.Id, signer.Id, 'Company', null)   // no record → stays blank
        };

        Test.startTest();
        DocumentGenerationService.prefillAgreementFields(agr.Id, null);
        Test.stopTest();

        for (Signature_Field__c f : [SELECT Field_Type__c, Field_Value__c
                FROM Signature_Field__c WHERE Agreement__c = :agr.Id]) {
            if (f.Field_Type__c == 'Email') {
                Assert.areEqual('sam@example.com', f.Field_Value__c, 'Email still fills from signer with no record');
            } else {
                Assert.isTrue(String.isBlank(f.Field_Value__c), 'Company stays blank with no record');
            }
        }
    }

    private static Signature_Field__c newField(Id agrId, Id signerId, String type, String presetValue) {
        return new Signature_Field__c(
            Agreement__c = agrId,
            Assigned_Signer__c = signerId,
            Field_Type__c = type,
            Field_Label__c = type,
            Page_Number__c = 1,
            X_Position__c = 100,
            Y_Position__c = 100,
            Width__c = 150,
            Height__c = 30,
            Is_Required__c = false,
            Page_Width__c = 762,
            Field_Value__c = presetValue
        );
    }
}
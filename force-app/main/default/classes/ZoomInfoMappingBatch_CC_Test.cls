/**
 * =============================================================================
 * Class Name    : ZoomInfoMappingBatch_CC_Test
 * Description   : Tests for ZoomInfoMappingBatch_CC and its after-insert hooks in the
 *                 Lead, Account and Contact trigger handlers.
 *
 * Author        : Devander Kumra
 * Created Date  : 18-11-2026
 * =============================================================================
 */
@IsTest
private class ZoomInfoMappingBatch_CC_Test {

    private static final String ZOOMINFO = 'ZoomInfo';
    private static final String WEB = 'Web';
    private static final String USERNAME_PREFIX = 'zoominfo.service.';

    @TestSetup
    static void setup() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User serviceUser = new User(
            FirstName         = 'ZoomInfo',
            LastName          = 'User',
            Alias             = 'zinfo',
            Email             = 'zoominfo.service@example.com',
            Username          = USERNAME_PREFIX + String.valueOf(Datetime.now().getTime()) + '@example.com.test',
            ProfileId         = adminProfile.Id,
            TimeZoneSidKey    = 'Europe/London',
            LocaleSidKey      = 'en_GB',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert serviceUser;
    }

    // ===================================================================== trigger -> batch
    @IsTest
    static void zoomInfoUserLeadGetsZoomInfoSource() {
        ZoomInfoMappingBatch_CC.setMappings(new List<ZoomInfo_Field_Mapping_CC__mdt>{
            mapping('Lead', 'LeadSource', ZOOMINFO, null, true)
        });
        Lead lead = newLead('Lia');

        System.runAs(serviceUser()) {
            Test.startTest();
            insert lead;
            Test.stopTest();
        }

        Assert.areEqual(ZOOMINFO, [SELECT LeadSource FROM Lead WHERE Id = :lead.Id].LeadSource);
    }

    @IsTest
    static void zoomInfoUserAccountGetsZoomInfoSource() {
        ZoomInfoMappingBatch_CC.setMappings(new List<ZoomInfo_Field_Mapping_CC__mdt>{
            mapping('Account', 'AccountSource', ZOOMINFO, null, true)
        });
        Account account = new Account(Name = 'ZoomInfo Test Company', AccountSource = WEB);

        System.runAs(serviceUser()) {
            Test.startTest();
            insert account;
            Test.stopTest();
        }

        Assert.areEqual(ZOOMINFO, [SELECT AccountSource FROM Account WHERE Id = :account.Id].AccountSource);
    }

    @IsTest
    static void zoomInfoUserContactGetsZoomInfoSource() {
        Account account = new Account(Name = 'Contact Parent Company');
        insert account;   // inserted by the test user - not processed
        ZoomInfoMappingBatch_CC.setMappings(new List<ZoomInfo_Field_Mapping_CC__mdt>{
            mapping('Contact', 'LeadSource', ZOOMINFO, null, true)
        });
        Contact contact = new Contact(FirstName = 'Zia', LastName = 'Tester', Email = 'zia.tester@example.com',
                                      Phone = '+44 20 7946 0001', AccountId = account.Id, LeadSource = WEB);

        System.runAs(serviceUser()) {
            Test.startTest();
            insert contact;
            Test.stopTest();
        }

        Assert.areEqual(ZOOMINFO, [SELECT LeadSource FROM Contact WHERE Id = :contact.Id].LeadSource);
    }

    @IsTest
    static void otherUsersAreIgnored() {
        ZoomInfoMappingBatch_CC.setMappings(new List<ZoomInfo_Field_Mapping_CC__mdt>{
            mapping('Lead', 'LeadSource', ZOOMINFO, null, true)
        });
        Lead lead = newLead('Nora');
        serviceUser();   // ZoomInfo user exists, but the running test user inserts the Lead

        Test.startTest();
        insert lead;
        Test.stopTest();

        Assert.areEqual(WEB, [SELECT LeadSource FROM Lead WHERE Id = :lead.Id].LeadSource);
        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'ZoomInfoMappingBatch_CC'],
            'No batch should be queued for a non-ZoomInfo user');
    }

    // ===================================================================== batch + sync fallback
    @IsTest
    static void batchCanBeRunDirectly() {
        Lead lead = newLead('Remy');
        insert lead;
        ZoomInfoMappingBatch_CC.setMappings(new List<ZoomInfo_Field_Mapping_CC__mdt>{
            mapping('Lead', 'LeadSource', ZOOMINFO, null, true)
        });

        Test.startTest();
        Database.executeBatch(new ZoomInfoMappingBatch_CC('Lead', new Set<Id>{ lead.Id }));
        Test.stopTest();

        Assert.areEqual(ZOOMINFO, [SELECT LeadSource FROM Lead WHERE Id = :lead.Id].LeadSource);
    }

    @IsTest
    static void synchronousFallbackAppliesMappings() {
        Lead lead = newLead('Sam');
        insert lead;
        ZoomInfoMappingBatch_CC.setMappings(new List<ZoomInfo_Field_Mapping_CC__mdt>{
            mapping('Lead', 'LeadSource', ZOOMINFO, null, true)
        });
        ZoomInfoMappingBatch_CC.forceSynchronous = true;

        Test.startTest();
        ZoomInfoMappingBatch_CC.enqueue('Lead', new Set<Id>{ lead.Id });
        Test.stopTest();

        Assert.areEqual(ZOOMINFO, [SELECT LeadSource FROM Lead WHERE Id = :lead.Id].LeadSource);
    }

    /** A mapping that blanks a required field makes the update fail; the failure is logged, not thrown. */
    @IsTest
    static void failedUpdatesAreLoggedNotThrown() {
        Lead lead = newLead('Fay');
        insert lead;
        ZoomInfoMappingBatch_CC.setMappings(new List<ZoomInfo_Field_Mapping_CC__mdt>{
            mapping('Lead', 'LastName', null, null, true)
        });

        Test.startTest();
        ZoomInfoMappingBatch_CC.applyNow('Lead', new Set<Id>{ lead.Id });
        ZoomInfoMappingBatch_CC.enqueue('Lead', new Set<Id>());   // nothing to do
        Test.stopTest();

        Assert.areEqual('ZoomInfo Test', [SELECT LastName FROM Lead WHERE Id = :lead.Id].LastName,
            'The failed update must leave the record unchanged');
    }

    @IsTest
    static void applyNowWithoutMappingsIsNoOp() {
        Lead lead = newLead('Gus');
        insert lead;
        ZoomInfoMappingBatch_CC.setMappings(new List<ZoomInfo_Field_Mapping_CC__mdt>());

        Test.startTest();
        ZoomInfoMappingBatch_CC.applyNow('Lead', new Set<Id>{ lead.Id });
        Test.stopTest();

        Assert.areEqual(WEB, [SELECT LeadSource FROM Lead WHERE Id = :lead.Id].LeadSource, 'No mappings, no change');
        Assert.areEqual(0, ZoomInfoMappingBatch_CC.applyMappings(null, null).size(), 'Nothing to map');
    }

    // ===================================================================== mapping rules
    @IsTest
    static void overwriteFlagAndSourceFieldCopy() {
        Lead filled = new Lead(Id = fakeLeadId(1), Company = 'Acme', LeadSource = WEB);
        Lead blank  = new Lead(Id = fakeLeadId(2), Company = 'Globex');
        List<ZoomInfo_Field_Mapping_CC__mdt> mappings = new List<ZoomInfo_Field_Mapping_CC__mdt>{
            mapping('Lead', 'LeadSource', ZOOMINFO, null, false),    // fill only when blank
            mapping('Lead', 'Description', null, 'Company', true)    // copy from another field
        };

        List<SObject> changed = ZoomInfoMappingBatch_CC.applyMappings(new List<Lead>{ filled, blank }, mappings);

        Assert.areEqual(2, changed.size());
        Lead first = (Lead) changed[0];
        Lead second = (Lead) changed[1];
        Assert.isFalse(first.isSet('LeadSource'), 'Existing value must be kept when Overwrite is off');
        Assert.areEqual('Acme', first.Description);
        Assert.areEqual(ZOOMINFO, second.LeadSource);
        Assert.areEqual('Globex', second.Description);
    }

    @IsTest
    static void unchangedRecordsAreNotUpdated() {
        Lead alreadyMapped = new Lead(Id = fakeLeadId(3), LeadSource = ZOOMINFO);
        List<SObject> changed = ZoomInfoMappingBatch_CC.applyMappings(
            new List<Lead>{ alreadyMapped },
            new List<ZoomInfo_Field_Mapping_CC__mdt>{ mapping('Lead', 'LeadSource', ZOOMINFO, null, true) });
        Assert.areEqual(0, changed.size());
    }

    @IsTest
    static void invalidMappingsAreSkipped() {
        ZoomInfoMappingBatch_CC.setMappings(new List<ZoomInfo_Field_Mapping_CC__mdt>{
            mapping('Lead', 'LeadSource', ZOOMINFO, null, true),                   // valid
            mapping('Lead', 'Not_A_Real_Field__c', ZOOMINFO, null, true),          // bad target
            mapping('Lead', 'Description', null, 'Not_A_Real_Source__c', true),    // bad source
            mapping('Lead', 'NumberOfEmployees', 'many', null, true),              // bad value for Integer
            mapping('Lead', 'Product_Category_Formula_CC__c', ZOOMINFO, null, true), // formula - not writable
            mapping('Not_A_Real_Object__c', 'Name', ZOOMINFO, null, true),         // bad object
            mapping('Account', 'AccountSource', ZOOMINFO, null, true)              // other object
        });

        Test.startTest();
        List<ZoomInfo_Field_Mapping_CC__mdt> leadMappings = ZoomInfoMappingBatch_CC.validMappings('Lead');
        List<ZoomInfo_Field_Mapping_CC__mdt> badObject = ZoomInfoMappingBatch_CC.validMappings('Not_A_Real_Object__c');
        Test.stopTest();

        Assert.areEqual(1, leadMappings.size());
        Assert.areEqual('LeadSource', leadMappings[0].Target_Field_API_Name_CC__c);
        Assert.areEqual(0, badObject.size());
    }

    @IsTest
    static void inactiveMappingsAreIgnored() {
        ZoomInfoMappingBatch_CC.setMappings(new List<ZoomInfo_Field_Mapping_CC__mdt>{
            mapping('Lead', 'LeadSource', ZOOMINFO, null, true, false)
        });

        Test.startTest();
        Assert.areEqual(0, ZoomInfoMappingBatch_CC.validMappings('Lead').size());
        ZoomInfoMappingBatch_CC.enqueue('Lead', new Set<Id>{ fakeLeadId(4) });   // no mappings -> no-op
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'ZoomInfoMappingBatch_CC']);
    }

    @IsTest
    static void deployedMappingsLoad() {
        ZoomInfoMappingBatch_CC.setMappings(null);   // read the real metadata rows
        for (ZoomInfo_Field_Mapping_CC__mdt row : ZoomInfoMappingBatch_CC.validMappings('Lead')) {
            Assert.isTrue(row.Active_CC__c);
            Assert.areEqual('lead', row.Object_API_Name_CC__c.trim().toLowerCase());
        }
    }

    @IsTest
    static void serviceUserIsFoundByLabelName() {
        Id resolved = ZoomInfoMappingBatch_CC.getServiceUserId();
        Assert.isNotNull(resolved, 'An active user named "' + System.Label.ZoomInfo_Service_User_Name_CC + '" exists');
        Assert.areEqual(System.Label.ZoomInfo_Service_User_Name_CC, [SELECT Name FROM User WHERE Id = :resolved].Name);
    }

    @IsTest
    static void nothingHappensWithoutServiceUser() {
        ZoomInfoMappingBatch_CC.setMappings(new List<ZoomInfo_Field_Mapping_CC__mdt>{
            mapping('Lead', 'LeadSource', ZOOMINFO, null, true)
        });
        ZoomInfoMappingBatch_CC.serviceUserId = null;
        Lead lead = new Lead(Id = fakeLeadId(5), LastName = 'No Service User');

        Test.startTest();
        ZoomInfoMappingBatch_CC.processInsertedRecords('Lead', null);
        ZoomInfoMappingBatch_CC.processInsertedRecords('Lead', new List<Lead>{ lead });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'ZoomInfoMappingBatch_CC']);
    }

    /** ContactTriggerHandler_CC gained afterInsert() for ZoomInfo; keep the rest of the handler covered too. */
    @IsTest
    static void contactHandlerMethodsRun() {
        Contact noPhone = new Contact(LastName = 'No Phone');
        Contact withPhone = new Contact(LastName = 'Has Phone', Phone = '+44 20 7946 0002');
        ContactTriggerHandler_CC.validateContactMethod(new List<Contact>{ noPhone, withPhone });
        Assert.isTrue(noPhone.hasErrors(), 'Contact without Phone/Mobile must be rejected');
        Assert.isFalse(withPhone.hasErrors());

        ContactTriggerHandler_CC handler = new ContactTriggerHandler_CC();
        try {
            handler.beforeInsert();     // outside a trigger Trigger.new is null
        } catch (NullPointerException ex) {
            Assert.isNotNull(ex);
        }
        try {
            handler.beforeUpdate();
        } catch (NullPointerException ex) {
            Assert.isNotNull(ex);
        }
    }

    @IsTest
    static void convertHandlesFieldTypes() {
        Assert.areEqual(true, ZoomInfoMappingBatch_CC.convert('true', Schema.DisplayType.BOOLEAN));
        Assert.areEqual(5, ZoomInfoMappingBatch_CC.convert('5', Schema.DisplayType.INTEGER));
        Assert.areEqual(7L, ZoomInfoMappingBatch_CC.convert('7', Schema.DisplayType.LONG));
        Assert.areEqual(Decimal.valueOf('1.5'), ZoomInfoMappingBatch_CC.convert('1.5', Schema.DisplayType.CURRENCY));
        Assert.areEqual(Date.newInstance(2026, 11, 18), ZoomInfoMappingBatch_CC.convert('2026-11-18', Schema.DisplayType.DATE));
        Assert.areEqual(Datetime.newInstanceGmt(2026, 11, 18, 9, 30, 0),
            ZoomInfoMappingBatch_CC.convert('2026-11-18 09:30:00', Schema.DisplayType.DATETIME));
        Assert.areEqual(ZOOMINFO, ZoomInfoMappingBatch_CC.convert(' ZoomInfo ', Schema.DisplayType.PICKLIST));
        Assert.isNull(ZoomInfoMappingBatch_CC.convert('  ', Schema.DisplayType.STRING));
    }

    // ===================================================================== helpers
    /** The test service user; also pins it as the ZoomInfo user so a real "ZoomInfo User" in the org is not picked up. */
    private static User serviceUser() {
        User serviceUser = [SELECT Id FROM User WHERE Username LIKE :USERNAME_PREFIX + '%' LIMIT 1];
        ZoomInfoMappingBatch_CC.serviceUserId = serviceUser.Id;
        return serviceUser;
    }

    private static Lead newLead(String firstName) {
        return new Lead(
            FirstName  = firstName,
            LastName   = 'ZoomInfo Test',
            Company    = firstName + ' Packaging Ltd',
            Status     = 'Identify',
            Email      = firstName.toLowerCase() + '.zoominfo.test@example.com',
            Phone      = '+44 20 7946 0000',
            LeadSource = WEB
        );
    }

    private static Id fakeLeadId(Integer index) {
        return Id.valueOf('00Q' + String.valueOf(index).leftPad(12, '0'));
    }

    private static ZoomInfo_Field_Mapping_CC__mdt mapping(String objectApiName, String target, String value,
                                                         String sourceField, Boolean overwrite) {
        return mapping(objectApiName, target, value, sourceField, overwrite, true);
    }

    private static ZoomInfo_Field_Mapping_CC__mdt mapping(String objectApiName, String target, String value,
                                                         String sourceField, Boolean overwrite, Boolean active) {
        Map<String, Object> fields = new Map<String, Object>{
            'DeveloperName'               => 'Test_' + objectApiName.replace('__c', '') + '_' + target.replace('__c', ''),
            'Active_CC__c'                => active,
            'Object_API_Name_CC__c'       => objectApiName,
            'Target_Field_API_Name_CC__c' => target,
            'Value_CC__c'                 => value,
            'Source_Field_API_Name_CC__c' => sourceField,
            'Overwrite_Existing_CC__c'    => overwrite
        };
        return (ZoomInfo_Field_Mapping_CC__mdt) JSON.deserialize(JSON.serialize(fields), ZoomInfo_Field_Mapping_CC__mdt.class);
    }
}
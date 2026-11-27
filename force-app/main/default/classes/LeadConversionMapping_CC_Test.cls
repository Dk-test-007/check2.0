/**
 * Tests the ten-question conversion mappings (LeadConvertSettings):
 *   Lead.Opportunity_Value_CC__c / Bespoke_Over_20_Percent_CC__c / Core_Category_Min_Qty_CC__c -> Opportunity
 *   Lead.Estimated_Annual_Spend_CC__c -> Account (never the Opportunity)
 *   CP27 (10 Nov): Actual_Annual_Spend_CC__c, Address_2_CC__c, Number_of_Locations_CC__c, Product_Category_CC__c -> Account;
 *   Pallet_Volume_Factor__c -> Daily_Pallet_Volume_CC__c, Sales appointment fields and Tender/Exclusive -> Opportunity
 * and that converting into an existing Account does not overwrite a populated spend.
 * Runs as the administrator: these tests cover field mapping, not access. Reads use WITH SYSTEM_MODE
 * because newly deployed fields have no FLS until Lead_UI_Rework_User_CC is assigned.
 */
@isTest
private class LeadConversionMapping_CC_Test {

    private static final Decimal OPPORTUNITY_VALUE = 125000;
    private static final Decimal LEAD_SPEND = 900000;
    private static final String PILOT_EMAIL = 'mapping.pilot@carltontest.invalid';
    private static Integer sequence = 0;

    @TestSetup
    static void setupPilotUser() {
        User pilot = new User(
            FirstName = 'Mapping', LastName = 'Pilot Sales', Alias = 'mappls', Email = PILOT_EMAIL,
            Username = 'mappls' + Math.abs(Crypto.getRandomLong()) + '@carltontest.invalid',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Carlton Sales User' LIMIT 1].Id,
            TimeZoneSidKey = 'America/Chicago', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert pilot;
        insert new PermissionSetAssignment(AssigneeId = pilot.Id,
            PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Lead_UI_Rework_User_CC' LIMIT 1].Id);
    }

    /**
     * CP27 (10 Nov): the Opportunity questions are mandatory on the Opportunity. A pilot user cannot move a New
     * Business Opportunity out of Discover until all six are answered; creating it (conversion) is not blocked.
     */
    @isTest
    static void newBusinessOpportunity_PilotUserMustAnswerQuestionsToLeaveDiscover() {
        User pilot = [SELECT Id FROM User WHERE Email = :PILOT_EMAIL LIMIT 1];
        Lead leadRecord = readyLead();
        leadRecord.OwnerId = pilot.Id;
        leadRecord.Opportunity_Value_CC__c = null;
        leadRecord.Bespoke_Over_20_Percent_CC__c = null;
        leadRecord.Core_Category_Min_Qty_CC__c = null;
        insert leadRecord;
        Database.LeadConvertResult converted = convert(leadRecord.Id, null, true);
        Assert.isTrue(converted.isSuccess(), 'Conversion must not need the Opportunity questions: ' + converted.getErrors());
        Id opportunityId = converted.getOpportunityId();
        update new Opportunity(Id = opportunityId, OwnerId = pilot.Id, StageName = 'Discover',
            RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('New_Business').getRecordTypeId());

        Database.SaveResult blocked;
        Database.SaveResult allowed;
        Test.setMock(HttpCalloutMock.class, new OkCallout());
        Test.startTest();
        System.runAs(pilot) {
            blocked = Database.update(new Opportunity(Id = opportunityId, StageName = 'Design'), false);
            allowed = Database.update(new Opportunity(Id = opportunityId, StageName = 'Design',
                Opportunity_Value_CC__c = 150000, Bespoke_Over_20_Percent_CC__c = 'No', Core_Category_Min_Qty_CC__c = 'Yes',
                Daily_Pallet_Volume_CC__c = palletBand('300 - 999'), Sales_Appointment_Booked_CC__c = 'Yes',
                Tender_Exclusive_Pricing_CC__c = 'Exclusive'), false);
        }
        Test.stopTest();

        Assert.isFalse(blocked.isSuccess(), 'Leaving Discover without the answers must be blocked');
        Assert.isTrue(String.valueOf(blocked.getErrors()).contains('Answer the qualification questions'), 'Unexpected: ' + blocked.getErrors());
        Assert.isTrue(allowed.isSuccess(), 'With every answer the Opportunity moves on: ' + allowed.getErrors());
    }

    private class OkCallout implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody('{}');
            return response;
        }
    }

    @isTest
    static void convertWithOpportunity_CarriesQuestionAnswersToOpportunityAndSpendToAccount() {
        Lead leadRecord = readyLead();
        insert leadRecord;

        Test.startTest();
        Database.LeadConvertResult result = convert(leadRecord.Id, null, true);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'Conversion should succeed: ' + result.getErrors());
        Opportunity opp = [SELECT Opportunity_Value_CC__c, Bespoke_Over_20_Percent_CC__c, Core_Category_Min_Qty_CC__c, Amount
                           FROM Opportunity WHERE Id = :result.getOpportunityId() WITH SYSTEM_MODE];
        Assert.areEqual(OPPORTUNITY_VALUE, opp.Opportunity_Value_CC__c, 'Q1 opportunity value should map to the Opportunity');
        Assert.areEqual('Yes', opp.Bespoke_Over_20_Percent_CC__c, 'Q3 should map to the Opportunity');
        Assert.areEqual('No', opp.Core_Category_Min_Qty_CC__c, 'Q4 should map to the Opportunity');
        Assert.areNotEqual(LEAD_SPEND, opp.Amount, 'Customer spend must never become the opportunity Amount');
        Assert.areEqual(LEAD_SPEND, accountSpend(result.getAccountId()), 'Q2 spend should map to the new Account');
    }

    /** CP27 (10 Nov): Account questions Q2, Q6, Q9 and Address 2 to the Account; Q5, Q8, Q10 to the Opportunity. */
    @isTest
    static void convertWithOpportunity_CarriesCp27AnswersToAccountAndOpportunity() {
        Datetime appointment = Datetime.newInstanceGmt(2026, 11, 3, 14, 0, 0);
        Lead leadRecord = readyLead();
        leadRecord.Actual_Annual_Spend_CC__c = 350000;
        leadRecord.Address_2_CC__c = 'Suite 400';
        leadRecord.Number_of_Locations_CC__c = 4;
        // Product_Category_CC__c also maps to Opportunity.Primary_Product_Category_CC__c, a restricted picklist whose
        // values differ from the Lead's for some categories (e.g. 'Palletwrap' vs 'Pallet Wrap'); use values valid on all three.
        leadRecord.Product_Category_CC__c = 'Cardboard;Tape';
        leadRecord.Pallet_Volume_Factor__c = palletBand('1,000+');
        leadRecord.Sales_Appointment_Booked_CC__c = 'Yes';
        leadRecord.First_Sales_Appointment_Date_CC__c = appointment;
        leadRecord.Tender_Exculsive_Pricing_CC__c = 'Tender';
        insert leadRecord;

        Test.startTest();
        Database.LeadConvertResult result = convert(leadRecord.Id, null, true);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'Conversion should succeed: ' + result.getErrors());
        Account account = [SELECT Actual_Annual_Spend_CC__c, Address_2_CC__c, Number_of_Locations_CC__c, Product_Category_CC__c
                           FROM Account WHERE Id = :result.getAccountId() WITH SYSTEM_MODE];
        Assert.areEqual(350000, account.Actual_Annual_Spend_CC__c, 'Q2 actual spend should map to the Account');
        Assert.areEqual('Suite 400', account.Address_2_CC__c, 'Address 2 should map to the Account');
        Assert.areEqual(4, account.Number_of_Locations_CC__c, 'Q6 number of locations should map to the Account');
        Assert.areEqual('Cardboard;Tape', account.Product_Category_CC__c, 'Q9 product categories should map to the Account');
        Opportunity opp = [SELECT Daily_Pallet_Volume_CC__c, Sales_Appointment_Booked_CC__c, First_Sales_Appointment_Date_CC__c,
                           Tender_Exclusive_Pricing_CC__c, Amount
                           FROM Opportunity WHERE Id = :result.getOpportunityId() WITH SYSTEM_MODE];
        Assert.areEqual(palletBand('1,000+'), opp.Daily_Pallet_Volume_CC__c, 'Q5 daily pallet volume should map to the Opportunity');
        Assert.areEqual('Yes', opp.Sales_Appointment_Booked_CC__c, 'Q8 appointment booked should map to the Opportunity');
        Assert.areEqual(appointment, opp.First_Sales_Appointment_Date_CC__c, 'Q8 appointment date should map to the Opportunity');
        Assert.areEqual('Tender', opp.Tender_Exclusive_Pricing_CC__c, 'Q10 tender/exclusive should map to the Opportunity');
        Assert.areNotEqual(350000, opp.Amount, 'Actual spend must never become the opportunity Amount');
    }

    /** The Lead pallet band whose label starts with the given text (the live values end with a space). */
    private static String palletBand(String startsWith) {
        for (Schema.PicklistEntry entry : Lead.Pallet_Volume_Factor__c.getDescribe().getPicklistValues()) {
            if (entry.isActive() && entry.getValue().trim() == startsWith) {
                return entry.getValue();
            }
        }
        Assert.fail('No pallet band ' + startsWith);
        return null;
    }

    @isTest
    static void convertWithoutOpportunity_StillCarriesSpendToAccount() {
        Lead leadRecord = readyLead();
        insert leadRecord;

        Test.startTest();
        Database.LeadConvertResult result = convert(leadRecord.Id, null, false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'Conversion should succeed: ' + result.getErrors());
        Assert.isNull(result.getOpportunityId(), 'No Opportunity should be created');
        Assert.areEqual(LEAD_SPEND, accountSpend(result.getAccountId()), 'Account facts carry over without an Opportunity');
    }

    @isTest
    static void convertIntoExistingAccount_KeepsPopulatedSpendAndFillsBlankSpend() {
        Account populated = new Account(Name = 'ZZTEST Populated Spend ' + Crypto.getRandomInteger(), Estimated_Annual_Spend_CC__c = 50000);
        Account blank = new Account(Name = 'ZZTEST Blank Spend ' + Crypto.getRandomInteger());
        insert new List<Account>{ populated, blank };
        Lead intoPopulated = readyLead();
        Lead intoBlank = readyLead();
        insert new List<Lead>{ intoPopulated, intoBlank };

        Test.startTest();
        Database.LeadConvertResult populatedResult = convert(intoPopulated.Id, populated.Id, false);
        Database.LeadConvertResult blankResult = convert(intoBlank.Id, blank.Id, false);
        Test.stopTest();

        Assert.isTrue(populatedResult.isSuccess(), 'Conversion should succeed: ' + populatedResult.getErrors());
        Assert.isTrue(blankResult.isSuccess(), 'Conversion should succeed: ' + blankResult.getErrors());
        Assert.areEqual(50000, accountSpend(populated.Id), 'A populated existing-account spend must not be overwritten');
        Assert.areEqual(LEAD_SPEND, accountSpend(blank.Id), 'A blank existing-account spend is filled from the Lead');
    }

    // ---------------------------------------------------------------- Entity / Site
    // Apex conversion creates a new Account with the running user's default record type, which differs between orgs
    // (profiles are not deployed), so the Entity test converts into an existing Entity Account. The Lightning Convert
    // screen lets the user choose the record type; the new-Account path is covered by the manual smoke test.

    @isTest
    static void entityLead_ConvertsToEntityAccountWithSpend() {
        Account entity = new Account(Name = 'ZZTEST Entity Target ' + Crypto.getRandomInteger(), RecordTypeId = recordTypeId('Entity'));
        insert entity;
        Lead leadRecord = readyLead();
        leadRecord.Lead_Type_CC__c = 'Entity';
        insert leadRecord;

        Test.startTest();
        Database.LeadConvertResult result = convert(leadRecord.Id, entity.Id, false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'Entity conversion should succeed: ' + result.getErrors());
        Account converted = [SELECT RecordType.DeveloperName, Lead_Type_CC__c, Estimated_Annual_Spend_CC__c
                             FROM Account WHERE Id = :result.getAccountId() WITH SYSTEM_MODE];
        Assert.areEqual('Entity', converted.RecordType.DeveloperName, 'An Entity Lead becomes an Entity Account');
        Assert.areEqual(LEAD_SPEND, converted.Estimated_Annual_Spend_CC__c, 'Spend lands on the Entity');
    }

    @isTest
    static void siteLead_IntoExistingSite_KeepsEntityParentAndLeavesEntitySpendAlone() {
        Account entity = new Account(Name = 'ZZTEST Entity ' + Crypto.getRandomInteger(), RecordTypeId = recordTypeId('Entity'),
                                     Estimated_Annual_Spend_CC__c = 5000000);
        insert entity;
        Account site = new Account(Name = 'ZZTEST Site ' + Crypto.getRandomInteger(), RecordTypeId = recordTypeId('Site'), ParentId = entity.Id);
        insert site;
        Lead leadRecord = readyLead();
        leadRecord.Lead_Type_CC__c = 'Site';
        leadRecord.Entity_Associated_CC__c = entity.Id;
        insert leadRecord;

        Test.startTest();
        Database.LeadConvertResult result = convert(leadRecord.Id, site.Id, false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'Site conversion into an existing Site should succeed: ' + result.getErrors());
        Account convertedSite = [SELECT ParentId, Estimated_Annual_Spend_CC__c FROM Account WHERE Id = :site.Id WITH SYSTEM_MODE];
        Assert.areEqual(entity.Id, convertedSite.ParentId, 'The Site keeps its Entity parent');
        Assert.areEqual(LEAD_SPEND, convertedSite.Estimated_Annual_Spend_CC__c, 'The Site Lead spend lands on the Site');
        Assert.areEqual(5000000, accountSpend(entity.Id), 'The Entity spend is not touched by a Site conversion');
    }

    @isTest
    static void siteLead_IntoNewNonSiteAccount_IsRejectedByAccountHandler() {
        Account entity = new Account(Name = 'ZZTEST Entity ' + Crypto.getRandomInteger(), RecordTypeId = recordTypeId('Entity'));
        insert entity;
        Lead leadRecord = readyLead();
        leadRecord.Lead_Type_CC__c = 'Site';
        leadRecord.Entity_Associated_CC__c = entity.Id;
        insert leadRecord;
        Boolean defaultIsSite = defaultAccountRecordType() == 'Site';

        Test.startTest();
        Database.LeadConvertResult result = convert(leadRecord.Id, null, false);
        Test.stopTest();

        if (defaultIsSite) {
            Assert.isTrue(result.isSuccess(), 'Conversion should succeed: ' + result.getErrors());
            Assert.areEqual(entity.Id, [SELECT ParentId FROM Account WHERE Id = :result.getAccountId() WITH SYSTEM_MODE].ParentId,
                'A new Site is parented to the Lead\'s Entity');
        } else {
            Assert.isFalse(result.isSuccess(), 'A Site Lead must not become a non-Site Account');
            Assert.isTrue(String.valueOf(result.getErrors()).contains('Site record type'), 'Unexpected error: ' + result.getErrors());
        }
    }

    private static Id recordTypeId(String developerName) {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get(developerName).getRecordTypeId();
    }

    private static String defaultAccountRecordType() {
        for (Schema.RecordTypeInfo info : Schema.SObjectType.Account.getRecordTypeInfos()) {
            if (info.isDefaultRecordTypeMapping()) {
                return info.getDeveloperName();
            }
        }
        return null;
    }

    /** An Engage Lead with Meeting Outcome "Qualified", which Lead_conversion_validation accepts. */
    private static Lead readyLead() {
        sequence++;
        String suffix = String.valueOf(sequence) + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new Lead(
            FirstName = 'Mapping', LastName = 'Tester ' + suffix, Company = 'ZZTEST Mapping Co ' + suffix,
            Status = 'Engage', Meeting_Outcome_CC__c = LeadStageTransitionService_CC.MEETING_OUTCOME_QUALIFIED,
            Email = 'mapping' + suffix + '@carltontest.invalid', City = 'Chicago', PostalCode = '60601', CountryCode = 'US',
            Opportunity_Value_CC__c = OPPORTUNITY_VALUE, Bespoke_Over_20_Percent_CC__c = 'Yes',
            Core_Category_Min_Qty_CC__c = 'No', Estimated_Annual_Spend_CC__c = LEAD_SPEND
        );
    }

    private static Database.LeadConvertResult convert(Id leadId, Id accountId, Boolean createOpportunity) {
        Database.LeadConvert request = new Database.LeadConvert();
        request.setLeadId(leadId);
        request.setConvertedStatus([SELECT ApiName FROM LeadStatus WHERE IsConverted = true LIMIT 1].ApiName);
        if (accountId != null) {
            request.setAccountId(accountId);
        }
        request.setDoNotCreateOpportunity(!createOpportunity);
        if (createOpportunity) {
            request.setOpportunityName('ZZTEST Tape x500');
        }
        return Database.convertLead(request, false);
    }

    private static Decimal accountSpend(Id accountId) {
        return [SELECT Estimated_Annual_Spend_CC__c FROM Account WHERE Id = :accountId WITH SYSTEM_MODE].Estimated_Annual_Spend_CC__c;
    }
}
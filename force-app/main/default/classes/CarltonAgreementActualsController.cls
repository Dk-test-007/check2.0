public with sharing class CarltonAgreementActualsController {
    public class AgreementChoice {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String actualsMode { get; set; }
    }

    public class ActualRow {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public Id agreementId { get; set; }
        @AuraEnabled public String agreementName { get; set; }
        @AuraEnabled public Id opportunityId { get; set; }
        @AuraEnabled public String opportunityName { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public String monthKey { get; set; }
        @AuraEnabled public String monthLabel { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Decimal sourceActual { get; set; }
        @AuraEnabled public Decimal forecastQuantity { get; set; }
        @AuraEnabled public Decimal forecastRevenueBasis { get; set; }
        @AuraEnabled public Decimal salesPrice { get; set; }
        @AuraEnabled public Decimal effectiveActual { get; set; }
        @AuraEnabled public Decimal overrideAmount { get; set; }
        @AuraEnabled public Boolean hasOverride { get; set; }
        @AuraEnabled public Datetime lastChangedAt { get; set; }
        @AuraEnabled public String lastChangedBy { get; set; }
        @AuraEnabled public String lastReason { get; set; }
    }

    public class Overview {
        @AuraEnabled public List<AgreementChoice> agreements { get; set; }
        @AuraEnabled public List<ActualRow> rows { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static Overview getOverview(Id accountId) {
        Overview result = new Overview();
        result.agreements = new List<AgreementChoice>();
        result.rows = new List<ActualRow>();
        if (accountId == null) return result;

        List<SalesAgreement> agreements = [
            SELECT Id, Name, ActualsCalculationMode
            FROM SalesAgreement WHERE AccountId = :accountId
            ORDER BY Name LIMIT 500
        ];
        Set<Id> agreementIds = new Set<Id>();
        for (SalesAgreement agreement : agreements) {
            agreementIds.add(agreement.Id);
            AgreementChoice choice = new AgreementChoice();
            choice.id = agreement.Id;
            choice.name = agreement.Name;
            choice.actualsMode = agreement.ActualsCalculationMode;
            result.agreements.add(choice);
        }
        if (agreementIds.isEmpty()) return result;

        Map<Id, SalesAgreementProduct> products = new Map<Id, SalesAgreementProduct>([
            SELECT Id, Name, SalesAgreementId, SalesAgreement.Name,
                SalesAgreement.Source_Opportunity_CC__c, SalesAgreement.Source_Opportunity_CC__r.Name
            FROM SalesAgreementProduct
            WHERE SalesAgreementId IN :agreementIds
            ORDER BY SalesAgreement.Name, Name LIMIT 2000
        ]);
        if (products.isEmpty()) return result;
        Set<Id> productIds = products.keySet();

        List<SalesAgreementProductSchedule> schedules = [
            SELECT Id, StartDate, SalesAgreementProductId,
                CurrencyIsoCode, ActualAmount, ForecastedQuantity, ForecastedQuantityValue, SalesPrice
            FROM SalesAgreementProductSchedule
            WHERE SalesAgreementProductId IN :productIds
            ORDER BY StartDate, SalesAgreementProductId LIMIT 10000
        ];
        Set<String> scheduleKeys = new Set<String>();
        for (SalesAgreementProductSchedule schedule : schedules) {
            scheduleKeys.add(String.valueOf(schedule.Id));
        }
        Map<String, CarltonAgreementActualChange__c> latest = new Map<String, CarltonAgreementActualChange__c>();
        if (!scheduleKeys.isEmpty()) {
            for (CarltonAgreementActualChange__c change : [
                SELECT Id, SalesAgreementProductScheduleId__c, RecordedActualRevenue__c,
                    UseOrderActual__c, Reason__c, CreatedDate, CreatedBy.Name
                FROM CarltonAgreementActualChange__c
                WHERE Account__c = :accountId
                    AND SalesAgreementProductScheduleId__c IN :scheduleKeys
                ORDER BY CreatedDate DESC, Id DESC LIMIT 10000
            ]) {
                if (!latest.containsKey(change.SalesAgreementProductScheduleId__c)) {
                    latest.put(change.SalesAgreementProductScheduleId__c, change);
                }
            }
        }
        for (SalesAgreementProductSchedule schedule : schedules) {
            SalesAgreementProduct product = products.get(schedule.SalesAgreementProductId);
            ActualRow row = new ActualRow();
            row.id = schedule.Id;
            row.agreementId = product.SalesAgreementId;
            row.agreementName = product.SalesAgreement.Name;
            row.opportunityId = product.SalesAgreement.Source_Opportunity_CC__c;
            row.opportunityName = product.SalesAgreement.Source_Opportunity_CC__r == null
                ? null : product.SalesAgreement.Source_Opportunity_CC__r.Name;
            row.productName = product.Name;
            row.monthKey = String.valueOf(schedule.StartDate);
            row.monthLabel = DateTime.newInstance(schedule.StartDate, Time.newInstance(12, 0, 0, 0)).format('MMM yyyy');
            row.currencyCode = schedule.CurrencyIsoCode;
            row.sourceActual = schedule.ActualAmount == null ? 0 : schedule.ActualAmount;
            row.forecastQuantity = schedule.ForecastedQuantityValue == null ? schedule.ForecastedQuantity : schedule.ForecastedQuantityValue;
            row.salesPrice = schedule.SalesPrice;
            row.forecastRevenueBasis = (row.forecastQuantity == null || row.salesPrice == null)
                ? 0 : row.forecastQuantity * row.salesPrice;
            CarltonAgreementActualChange__c change = latest.get(String.valueOf(schedule.Id));
            row.hasOverride = change != null && !change.UseOrderActual__c;
            row.overrideAmount = row.hasOverride ? change.RecordedActualRevenue__c : null;
            row.effectiveActual = row.hasOverride ? row.overrideAmount : row.sourceActual;
            if (change != null) {
                row.lastChangedAt = change.CreatedDate;
                row.lastChangedBy = change.CreatedBy.Name;
                row.lastReason = change.Reason__c;
            }
            result.rows.add(row);
        }
        return result;
    }

    @AuraEnabled
    public static Id saveActual(Id accountId, Id scheduleId, Decimal overrideAmount,
        Boolean useSourceActual, String reason) {
        if (accountId == null || scheduleId == null) {
            throw new AuraHandledException('Select an account, agreement product, and month.');
        }
        if (String.isBlank(reason) || reason.length() > 2000) {
            throw new AuraHandledException('Enter a source or reason, up to 2,000 characters.');
        }
        if (useSourceActual != true && (overrideAmount == null || overrideAmount < 0)) {
            throw new AuraHandledException('Enter a nonnegative actual revenue amount.');
        }
        List<SalesAgreementProductSchedule> matches = [
            SELECT Id, StartDate, SalesAgreementProductId,
                SalesAgreementProduct.SalesAgreementId,
                SalesAgreementProduct.SalesAgreement.AccountId,
                CurrencyIsoCode, ActualAmount
            FROM SalesAgreementProductSchedule
            WHERE Id = :scheduleId LIMIT 1
        ];
        if (matches.isEmpty() || matches[0].SalesAgreementProduct.SalesAgreement.AccountId != accountId) {
            throw new AuraHandledException('The schedule does not belong to this account.');
        }
        SalesAgreementProductSchedule schedule = matches[0];
        Decimal sourceAmount = schedule.ActualAmount == null ? 0 : schedule.ActualAmount;
        Decimal previousEffective = sourceAmount;
        String scheduleKey = String.valueOf(scheduleId);
        List<CarltonAgreementActualChange__c> previous = [
            SELECT RecordedActualRevenue__c, UseOrderActual__c
            FROM CarltonAgreementActualChange__c
            WHERE Account__c = :accountId
                AND SalesAgreementProductScheduleId__c = :scheduleKey
            ORDER BY CreatedDate DESC, Id DESC LIMIT 1
        ];
        if (!previous.isEmpty() && !previous[0].UseOrderActual__c) {
            previousEffective = previous[0].RecordedActualRevenue__c;
        }
        CarltonAgreementActualChange__c entry = new CarltonAgreementActualChange__c();
        entry.Account__c = accountId;
        entry.SalesAgreement__c = schedule.SalesAgreementProduct.SalesAgreementId;
        entry.SalesAgreementProductId__c = String.valueOf(schedule.SalesAgreementProductId);
        entry.SalesAgreementProductScheduleId__c = scheduleKey;
        entry.PeriodStartDate__c = schedule.StartDate;
        entry.CurrencyIsoCode = schedule.CurrencyIsoCode;
        entry.OrderActualRevenueAtEntry__c = sourceAmount;
        entry.PreviousEffectiveActualRevenue__c = previousEffective;
        entry.UseOrderActual__c = useSourceActual == true;
        entry.RecordedActualRevenue__c = useSourceActual == true ? null : overrideAmount;
        entry.Reason__c = reason.trim();
        insert entry;
        return entry.Id;
    }

    @AuraEnabled
    public static Id saveForecast(Id accountId, Id scheduleId, Decimal forecastQuantity, String reason) {
        if (accountId == null || scheduleId == null) {
            throw new AuraHandledException('Select an account, agreement product, and month.');
        }
        if (String.isBlank(reason) || reason.length() > 2000) {
            throw new AuraHandledException('Enter a source or reason, up to 2,000 characters.');
        }
        if (forecastQuantity == null || forecastQuantity < 0 || forecastQuantity != forecastQuantity.setScale(0)) {
            throw new AuraHandledException('Enter a nonnegative whole-unit forecast quantity.');
        }
        List<SalesAgreementProductSchedule> matches = [
            SELECT Id, StartDate, SalesAgreementProductId,
                SalesAgreementProduct.SalesAgreementId,
                SalesAgreementProduct.SalesAgreement.AccountId,
                CurrencyIsoCode, ForecastedQuantity, ForecastedQuantityValue, SalesPrice
            FROM SalesAgreementProductSchedule
            WHERE Id = :scheduleId LIMIT 1 FOR UPDATE
        ];
        if (matches.isEmpty() || matches[0].SalesAgreementProduct.SalesAgreement.AccountId != accountId) {
            throw new AuraHandledException('The schedule does not belong to this account.');
        }
        SalesAgreementProductSchedule schedule = matches[0];
        Decimal previousQuantity = schedule.ForecastedQuantityValue == null
            ? schedule.ForecastedQuantity : schedule.ForecastedQuantityValue;
        Decimal salesPrice = schedule.SalesPrice == null ? 0 : schedule.SalesPrice;
        SalesAgreementProductSchedule edit = new SalesAgreementProductSchedule(
            Id = schedule.Id,
            ForecastedQuantity = forecastQuantity.intValue(),
            ForecastedQuantityValue = forecastQuantity
        );
        update edit;

        CarltonAgreementForecastChange__c entry = new CarltonAgreementForecastChange__c();
        entry.Account__c = accountId;
        entry.SalesAgreement__c = schedule.SalesAgreementProduct.SalesAgreementId;
        entry.SalesAgreementProductScheduleId__c = String.valueOf(scheduleId);
        entry.PeriodStartDate__c = schedule.StartDate;
        entry.CurrencyIsoCode = schedule.CurrencyIsoCode;
        entry.PreviousQuantity__c = previousQuantity;
        entry.NewQuantity__c = forecastQuantity;
        entry.PreviousRevenueBasis__c = previousQuantity * salesPrice;
        entry.NewRevenueBasis__c = forecastQuantity * salesPrice;
        entry.Reason__c = reason.trim();
        insert entry;
        return entry.Id;
    }
}
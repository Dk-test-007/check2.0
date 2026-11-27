/**
 * Tests for CarltonAccountForecastController. Runs as the System Administrator running the tests.
 *
 * The account forecast needs the Carlton_Account_Product_Demand and Carlton_Account_Revenue_Only forecast sets
 * (AdvAccountForecastSet), which are deployed separately from the code. Until they are active in the org, the
 * controller refuses to start or change a forecast and the overview shows no rows; the tests assert that behaviour
 * there, and the full forecast behaviour once the sets are active.
 */
@IsTest
private class CarltonAccountForecastControllerTest {
    private static final String PRODUCT_SET = 'Carlton_Account_Product_Demand';
    private static final String REVENUE_SET = 'Carlton_Account_Revenue_Only';

    @TestSetup
    static void setup() {
        Account account = OpportunityUi2TestData_CC.entity(UserInfo.getUserId(), false);
        Product2 indicative = new Product2(Name = 'Indicative account revenue (unallocated products)',
            ProductCode = 'CARLTON-INDICATIVE-REVENUE', IsActive = true);
        insert indicative;
        PricebookEntry entry = OpportunityUi2TestData_CC.standardEntry('ZZTEST Forecast Product', 50, 'GBP');
        System.assertNotEquals(null, entry.Id);
        TestDmlRetry_CC.activateStandardPricebook();
        System.assertNotEquals(null, account.Id);
    }

    private static Account account() {
        return [SELECT Id, CurrencyIsoCode FROM Account WHERE Name LIKE 'ZZUI2 Entity%' LIMIT 1];
    }

    private static Boolean forecastSetActive(String developerName) {
        return [SELECT COUNT() FROM AdvAccountForecastSet WHERE DeveloperName = :developerName AND Status = 'Active'] == 1;
    }

    /** Asserts that starting a forecast is refused while the product forecast set is not active in the org. */
    private static void assertForecastRefused(Id accountId) {
        Boolean refused = false;
        try {
            CarltonAccountForecastController.ensureUnifiedForecast(accountId);
        } catch (AuraHandledException ex) {
            refused = true;
        }
        System.assert(refused, 'Without the product forecast set no forecast can be started.');
        System.assertEquals(null, CarltonAccountForecastController.getOverview(accountId).forecastUseId,
            'No forecast is created without the product forecast set.');
    }

    @IsTest
    static void forecastConfigurationIsVisibleToTests() {
        if (!forecastSetActive(PRODUCT_SET)) {
            assertForecastRefused(account().Id);
            return;
        }
        System.assert([SELECT COUNT() FROM Period WHERE Type = 'Month'
            AND StartDate >= :Date.today().toStartOfMonth()] >= 18,
            'The active 18-month forecast horizon must be available.');
    }

    @IsTest
    static void accountWithoutForecastShowsItsCurrencyAndNoRows() {
        Account account = account();
        CarltonAccountForecastController.ForecastOverview overview =
            CarltonAccountForecastController.getOverview(account.Id);
        System.assertEquals('GBP', overview.currencyCode);
        System.assert(overview.forecastFactCurrencyConsistent);
        System.assertEquals(0, overview.rows.size(), 'No forecast use has been generated for this test Account.');
        System.assertEquals(0, CarltonAccountForecastController.getRevenueOverview(account.Id).rows.size());
        System.assertEquals(0, CarltonAccountForecastController.getOverview(null).rows.size());
        System.assertEquals(0, CarltonAccountForecastController.getExistingProductOptions(null).size());
        List<CarltonAccountForecastController.ProductOption> options =
            CarltonAccountForecastController.getExistingProductOptions(account.Id);
        System.assertNotEquals(null, options, 'Product options should be available to the caller.');
    }

    @IsTest
    static void startsProductForecastForNewAccount() {
        Account account = account();
        if (!forecastSetActive(PRODUCT_SET)) {
            assertForecastRefused(account.Id);
            return;
        }
        Integer created = CarltonAccountForecastController.ensureUnifiedForecast(account.Id);
        System.assert(created > 0, 'The forecast should have a month for this account.');
        System.assertNotEquals(null, CarltonAccountForecastController.getOverview(account.Id).forecastUseId);
    }

    @IsTest
    static void addsProductAndSavesMonthlyAdjustments() {
        Account account = account();
        Product2 product = [SELECT Id FROM Product2 WHERE Name LIKE 'ZZTEST Forecast Product%' LIMIT 1];
        if (!forecastSetActive(PRODUCT_SET)) {
            Boolean refused = false;
            try {
                CarltonAccountForecastController.addExistingProduct(account.Id, product.Id);
            } catch (AuraHandledException ex) {
                refused = true;
            }
            System.assert(refused, 'A product cannot be added without the product forecast set.');
            return;
        }
        System.assertEquals(18, CarltonAccountForecastController.addExistingProduct(account.Id, product.Id));
        CarltonAccountForecastController.ForecastOverview overview =
            CarltonAccountForecastController.getOverview(account.Id);
        CarltonAccountForecastController.ForecastRow selected;
        for (CarltonAccountForecastController.ForecastRow row : overview.rows) {
            if (row.productId == product.Id) { selected = row; break; }
        }
        System.assertNotEquals(null, selected, 'The new product should appear in the account forecast.');
        CarltonAccountForecastController.ForecastEdit edit = new CarltonAccountForecastController.ForecastEdit();
        edit.factId = (Id) selected.key;
        edit.forecastQuantity = 5;
        edit.forecastRevenue = 250;
        System.assertEquals(1, CarltonAccountForecastController.saveForecastEdits(account.Id,
            new List<CarltonAccountForecastController.ForecastEdit>{edit}));
        AdvAccountForecastFact saved = [SELECT ForecastedQuantity, ForecastedRevenue,
            Carlton_Account_Adjustment_Quantity_CC__c, Carlton_Account_Adjustment_Revenue_CC__c
            FROM AdvAccountForecastFact WHERE Id = :edit.factId];
        System.assertEquals(5, saved.ForecastedQuantity);
        System.assertEquals(250, saved.ForecastedRevenue);
        System.assertEquals(5, saved.Carlton_Account_Adjustment_Quantity_CC__c);
        System.assertEquals(250, saved.Carlton_Account_Adjustment_Revenue_CC__c);
        System.assertEquals(1, CarltonAccountForecastController.changeProductForecast(account.Id, product.Id,
            selected.monthStart, selected.monthStart, 20));
        saved = [SELECT ForecastedQuantity, ForecastedRevenue FROM AdvAccountForecastFact WHERE Id = :edit.factId];
        System.assertEquals(6, saved.ForecastedQuantity);
        System.assertEquals(300, saved.ForecastedRevenue);
    }

    @IsTest
    static void syncsAndEditsRevenueForecast() {
        Account account = account();
        if (!forecastSetActive(REVENUE_SET)) {
            Boolean refused = false;
            try {
                CarltonAccountForecastController.syncRevenueForecast(account.Id);
            } catch (AuraHandledException ex) {
                refused = true;
            }
            System.assert(refused, 'The revenue forecast cannot be synced without the revenue forecast set.');
            return;
        }
        Integer created = CarltonAccountForecastController.syncRevenueForecast(account.Id);
        System.assertEquals(18, created);
        CarltonAccountForecastController.ForecastOverview overview =
            CarltonAccountForecastController.getRevenueOverview(account.Id);
        System.assertEquals(18, overview.rows.size());
        Date first = Date.today().toStartOfMonth();
        System.assertEquals(1, CarltonAccountForecastController.setMonthlyRevenue(account.Id, first, first, 125));
        System.assertEquals(125, CarltonAccountForecastController.getRevenueOverview(account.Id).rows[0].forecastRevenue);
    }

    @IsTest
    static void loadsAndStartsAccountForecast() {
        Account account = account();
        CarltonAccountForecastController.ForecastOverview before =
            CarltonAccountForecastController.getOverview(account.Id);
        System.assertEquals('GBP', before.currencyCode);
        if (!forecastSetActive(PRODUCT_SET)) {
            assertForecastRefused(account.Id);
            return;
        }
        System.assertEquals(18, CarltonAccountForecastController.ensureUnifiedForecast(account.Id));
        CarltonAccountForecastController.ForecastOverview after =
            CarltonAccountForecastController.getOverview(account.Id);
        System.assertNotEquals(null, after.forecastUseId);
        System.assertEquals(18, after.rows.size() / 2);
    }
}

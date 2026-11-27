/**
 * Opportunity UI2: the forecast measures, as pure functions of monthly maps (one currency at a time).
 *
 * - Attainment = Order Actuals / Original Plan, N/A (null) when the plan is zero.
 * - A month is Completed when it ends before today's month; the current month is Current (incomplete).
 * - Expected full-period outcome = Order Actuals for completed months + Current Forecast for the current and future
 *   months. Current-month actuals are not added on top of the current month's forecast.
 */
public with sharing class ForecastMetrics_CC {

    public static final String COMPLETED = 'Completed';
    public static final String CURRENT = 'Current (incomplete)';
    public static final String FUTURE = 'Future';

    public class PeriodTotals {
        public Decimal originalPlan = 0;
        public Decimal currentForecast = 0;
        public Decimal completedPlan = 0;
        public Decimal completedActuals = 0;
        public Decimal currentAndFutureForecast = 0;
        public Decimal expectedOutcome = 0;
        public String label;
    }

    public static String monthState(Date monthStart, Date today) {
        Date thisMonth = Date.newInstance(today.year(), today.month(), 1);
        if (monthStart < thisMonth) {
            return COMPLETED;
        }
        return monthStart == thisMonth ? CURRENT : FUTURE;
    }

    /** Percentage with one decimal place, or null when there is no plan to attain. */
    public static Decimal attainment(Decimal actual, Decimal plan) {
        if (plan == null || plan == 0) {
            return null;
        }
        return ((actual == null ? 0 : actual) * 100 / plan).setScale(1, System.RoundingMode.HALF_UP);
    }

    public static void add(Map<Date, Decimal> totals, Date month, Decimal value) {
        Decimal current = totals.get(month);
        totals.put(month, (current == null ? 0 : current) + (value == null ? 0 : value));
    }

    public static PeriodTotals periodTotals(Map<Date, Decimal> planByMonth, Map<Date, Decimal> forecastByMonth,
            Map<Date, Decimal> actualsByMonth, Date today) {
        PeriodTotals t = new PeriodTotals();
        Set<Date> months = new Set<Date>(planByMonth.keySet());
        months.addAll(forecastByMonth.keySet());
        Date first;
        Date last;
        for (Date month : months) {
            Decimal plan = valueOf(planByMonth, month);
            Decimal forecast = valueOf(forecastByMonth, month);
            t.originalPlan += plan;
            t.currentForecast += forecast;
            if (monthState(month, today) == COMPLETED) {
                t.completedPlan += plan;
                t.completedActuals += valueOf(actualsByMonth, month);
            } else {
                t.currentAndFutureForecast += forecast;
            }
            first = first == null || month < first ? month : first;
            last = last == null || month > last ? month : last;
        }
        t.expectedOutcome = t.completedActuals + t.currentAndFutureForecast;
        t.label = first == null ? 'No plan' : label(first) + ' to ' + label(last)
            + '. Completed months use Order Actuals; ' + label(Date.newInstance(today.year(), today.month(), 1))
            + ' onward uses the current forecast.';
        return t;
    }

    /**
     * Totals for one slice of the months: the original term, the extension, unplanned months (Orders but no plan) or
     * all of them combined. The slice is the months in planByMonth and forecastByMonth; give an unplanned month a
     * forecast of 0 to include it.
     */
    public class TermSplit {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Integer months { get; set; }
        @AuraEnabled public Date firstMonth { get; set; }
        @AuraEnabled public Date lastMonth { get; set; }
        @AuraEnabled public Decimal originalPlan { get; set; }
        @AuraEnabled public Decimal currentForecast { get; set; }
        /** Order Actuals in every month of the slice, including the current and future months. */
        @AuraEnabled public Decimal actualsToDate { get; set; }
        @AuraEnabled public Decimal completedPlan { get; set; }
        @AuraEnabled public Decimal completedActuals { get; set; }
        @AuraEnabled public Decimal completedVariance { get; set; }
        @AuraEnabled public Decimal completedAttainmentPercent { get; set; }
        @AuraEnabled public Decimal expectedOutcome { get; set; }
    }

    public static TermSplit termSplit(String label, Map<Date, Decimal> planByMonth, Map<Date, Decimal> forecastByMonth,
            Map<Date, Decimal> actualsByMonth, Date today) {
        PeriodTotals period = periodTotals(planByMonth, forecastByMonth, actualsByMonth, today);
        Set<Date> months = new Set<Date>(planByMonth.keySet());
        months.addAll(forecastByMonth.keySet());
        TermSplit s = new TermSplit();
        s.label = label;
        s.months = months.size();
        s.actualsToDate = 0;
        for (Date month : months) {
            s.actualsToDate += valueOf(actualsByMonth, month);
            s.firstMonth = s.firstMonth == null || month < s.firstMonth ? month : s.firstMonth;
            s.lastMonth = s.lastMonth == null || month > s.lastMonth ? month : s.lastMonth;
        }
        s.originalPlan = period.originalPlan;
        s.currentForecast = period.currentForecast;
        s.completedPlan = period.completedPlan;
        s.completedActuals = period.completedActuals;
        s.completedVariance = period.completedActuals - period.completedPlan;
        s.completedAttainmentPercent = attainment(period.completedActuals, period.completedPlan);
        s.expectedOutcome = period.expectedOutcome;
        return s;
    }

    public static Date firstOfMonth(Date d) {
        return d == null ? null : Date.newInstance(d.year(), d.month(), 1);
    }

    public static Decimal valueOf(Map<Date, Decimal> values, Date month) {
        Decimal value = values == null ? null : values.get(month);
        return value == null ? 0 : value;
    }

    public static String label(Date month) {
        return DateTime.newInstance(month, Time.newInstance(0, 0, 0, 0)).format('MMM yyyy');
    }
}
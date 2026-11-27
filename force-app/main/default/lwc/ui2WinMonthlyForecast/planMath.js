/** Pure helpers for the Win & Set Monthly Forecast panel (no LWC imports, so they run under plain Node tests). */

const MONTH_FORMAT = new Intl.DateTimeFormat(undefined, { month: 'short', year: 'numeric', timeZone: 'UTC' });

/** A usable win amount: a number above zero. Apex omits a null Amount, so it arrives as undefined. */
export function hasWinAmount(amount) {
    return typeof amount === 'number' && Number.isFinite(amount) && amount > 0;
}

export function equalSpread(total, months, decimals) {
    const factor = 10 ** decimals;
    const totalUnits = Math.round((hasWinAmount(total) ? total : 0) * factor);
    const base = Math.floor(totalUnits / months);
    const remainder = totalUnits - base * months;
    // Remainder units go to the last months so the total is exact.
    return Array.from({ length: months }, (_, i) => (base + (i >= months - remainder ? 1 : 0)) / factor);
}

export function sumAmounts(amounts, decimals) {
    const factor = 10 ** decimals;
    return amounts.reduce((acc, value) => acc + Math.round((Number(value) || 0) * factor), 0) / factor;
}

export function monthList(startIso, months) {
    const [year, month] = startIso.split('-').map(Number);
    return Array.from({ length: months }, (_, i) => {
        const d = new Date(Date.UTC(year, month - 1 + i, 1));
        return { key: d.toISOString().slice(0, 10), label: MONTH_FORMAT.format(d) };
    });
}

/** How the monthly total compares with the win amount, and the line shown under the months. */
export function reconcile(amount, total, decimals, currency) {
    if (!hasWinAmount(amount)) {
        return { hasAmount: false, reconciles: false, difference: 0, text: 'No win amount yet: add products to the Opportunity first.' };
    }
    const factor = 10 ** decimals;
    const difference = Math.round((amount - total) * factor) / factor;
    if (difference === 0) {
        return { hasAmount: true, reconciles: true, difference, text: 'Monthly plan equals the win amount.' };
    }
    return {
        hasAmount: true,
        reconciles: false,
        difference,
        text: `Monthly plan is ${difference > 0 ? 'short by' : 'over by'} ${currency} ${Math.abs(difference).toFixed(decimals)}.`
    };
}
/**
 * Several Orders at once (10 Nov): helpers for the multi-release grid on the agreement panel. Each row is one PO
 * release (release number, order date, product, quantity); the panel creates them one after another through the
 * existing createRelease service, so every row keeps the release-key duplicate check and gets its own result.
 */

export const STATE_PENDING = 'pending';
export const STATE_CREATED = 'created';
export const STATE_EXISTED = 'existed';
export const STATE_FAILED = 'failed';

const pad = (n) => String(n).padStart(2, '0');

/** ISO date `months` months after isoDate, keeping the day of month (clamped to the last day of a shorter month). */
export function addMonthsKeepDay(isoDate, months) {
    const [y, m, d] = isoDate.split('-').map(Number);
    const target = new Date(Date.UTC(y, m - 1 + months, 1));
    const lastDay = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
    return `${target.getUTCFullYear()}-${pad(target.getUTCMonth() + 1)}-${pad(Math.min(d, lastDay))}`;
}

/** Next numeric release for a PO on this agreement, from release keys "agreementId|PO|release". */
export function nextReleaseNumber(poNumber, orders) {
    const po = (poNumber || '').trim();
    let max = 0;
    (orders || []).forEach((o) => {
        const parts = (o.releaseKey || '').split('|');
        if (parts.length >= 3 && parts[1] === po) {
            const n = parseInt(parts.slice(2).join('|'), 10);
            if (!Number.isNaN(n)) {
                max = Math.max(max, n);
            }
        }
    });
    return max + 1;
}

let sequence = 0;
export function newRow(values) {
    sequence += 1;
    return { key: `r${Date.now()}_${sequence}`, state: STATE_PENDING, message: '', orderId: undefined, orderNumber: undefined, ...values };
}

/** `count` monthly releases from `start`, numbered from `firstRelease`. */
export function monthlyRows({ start, count, firstRelease, agreementProductId, quantity }) {
    const n = Math.max(0, Math.min(24, Math.floor(Number(count) || 0)));
    const first = Math.max(1, Math.floor(Number(firstRelease) || 1));
    return Array.from({ length: n }, (_, i) => newRow({
        releaseNumber: String(first + i),
        orderDate: addMonthsKeepDay(start, i),
        agreementProductId,
        quantity: Number(quantity) || 1
    }));
}

/** A row after the last one: next release number, one month later, same product and quantity. */
export function nextRow(rows, defaults) {
    const last = rows[rows.length - 1];
    if (!last) {
        return newRow({ releaseNumber: String(defaults.firstRelease || 1), orderDate: defaults.start, agreementProductId: defaults.agreementProductId, quantity: 1 });
    }
    const release = parseInt(last.releaseNumber, 10);
    return newRow({
        releaseNumber: Number.isNaN(release) ? '' : String(release + 1),
        orderDate: last.orderDate ? addMonthsKeepDay(last.orderDate, 1) : defaults.start,
        agreementProductId: last.agreementProductId,
        quantity: last.quantity
    });
}

/** Problems that stop a submit before anything is sent (shared fields and every pending row). */
export function validateRows(shared, rows) {
    const problems = [];
    if (!(shared.poNumber || '').trim()) {
        problems.push('Enter the customer PO number.');
    }
    if (!shared.shipToSiteId) {
        problems.push('Choose the Ship-To Site.');
    }
    if (!shared.locationCode) {
        problems.push('Choose the location code.');
    }
    const pending = rows.filter((r) => r.state !== STATE_CREATED && r.state !== STATE_EXISTED);
    if (!pending.length) {
        problems.push('Add at least one release row.');
    }
    const seen = new Set();
    pending.forEach((r, i) => {
        const label = `Row ${i + 1}`;
        if (!r.orderDate) {
            problems.push(`${label}: enter the order date.`);
        }
        if (!r.agreementProductId) {
            problems.push(`${label}: choose the product.`);
        }
        if (!(Number(r.quantity) > 0)) {
            problems.push(`${label}: enter a quantity above zero.`);
        }
        const release = (r.releaseNumber || '').trim();
        if (!release) {
            problems.push(`${label}: enter the release number.`);
        } else if (seen.has(release)) {
            problems.push(`${label}: release ${release} is used twice in this list.`);
        }
        seen.add(release);
    });
    return problems;
}

/** The createRelease request for one row. */
export function requestFor(agreementId, shared, row) {
    return {
        agreementId,
        poNumber: shared.poNumber.trim(),
        releaseNumber: row.releaseNumber.trim(),
        orderDate: row.orderDate,
        shipToSiteId: shared.shipToSiteId,
        locationCode: shared.locationCode,
        shipmentMethod: shared.shipmentMethod,
        activateNow: shared.activateNow === true,
        lines: [{ agreementProductId: row.agreementProductId, quantity: Number(row.quantity) }]
    };
}

/** Row after its createRelease call (result or error message). */
export function applyResult(row, result, errorMessage) {
    if (errorMessage) {
        return { ...row, state: STATE_FAILED, message: errorMessage };
    }
    return {
        ...row,
        state: result.alreadyExisted ? STATE_EXISTED : STATE_CREATED,
        orderId: result.orderId,
        orderNumber: result.orderNumber,
        message: result.alreadyExisted ? `Already entered (${result.orderNumber}); nothing new created.` : `${result.orderNumber} ${result.status}`
    };
}

// ---------------------------------------------------------------- product choice (10 Nov)
// Products can be added to an agreement after the win (standard Sales Agreement Products list). The form reloads the
// agreement's products and re-checks every product choice: a product is only filled in automatically when the agreement
// has exactly one; with several, the user picks, so an outdated automatic choice can never be submitted.

/** The product to fill in automatically: the only product of the agreement, otherwise none. */
export function defaultProduct(productIds) {
    return productIds.length === 1 ? productIds[0] : undefined;
}

/** A product choice after the agreement's products were (re)loaded. `chosen` marks a choice the user made. */
export function reconcileProduct(current, chosen, productIds) {
    if (chosen && current && productIds.includes(current)) {
        return { value: current, chosen: true };
    }
    return { value: defaultProduct(productIds), chosen: false };
}

export function sameProducts(a, b) {
    return a.length === b.length && a.every((id, i) => id === b[i]);
}

/** Problems that stop a One Order submit before anything is sent. */
export function validateLines(lines) {
    const problems = [];
    if (!lines.length) {
        problems.push('Add at least one product line.');
    }
    lines.forEach((l, i) => {
        if (!l.agreementProductId) {
            problems.push(`Line ${i + 1}: choose the product.`);
        }
    });
    return problems;
}

export function summarize(rows) {
    const count = (state) => rows.filter((r) => r.state === state).length;
    const created = count(STATE_CREATED);
    const existed = count(STATE_EXISTED);
    const failed = count(STATE_FAILED);
    const parts = [`${created} created`];
    if (existed) {
        parts.push(`${existed} already entered`);
    }
    if (failed) {
        parts.push(`${failed} failed (still listed: correct and save again)`);
    }
    return { created, existed, failed, text: parts.join(', ') + '.' };
}
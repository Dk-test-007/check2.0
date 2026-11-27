/**
 * Local time for a Lead's address (CP27: "time zone difference based on the user's location and the location of the
 * lead record = local time"). The time zone comes from the address Country and State/Province codes; daylight
 * saving is handled by the browser's time zone data. States that span two zones use the zone most of the state is
 * in. Unknown countries return no zone, and the component then says the time zone is not known.
 */

const US_STATES = {
    'America/New_York': ['CT', 'DC', 'DE', 'FL', 'GA', 'IN', 'KY', 'MA', 'MD', 'ME', 'MI', 'NC', 'NH', 'NJ', 'NY', 'OH',
        'PA', 'RI', 'SC', 'VA', 'VT', 'WV'],
    'America/Chicago': ['AL', 'AR', 'IA', 'IL', 'KS', 'LA', 'MN', 'MO', 'MS', 'ND', 'NE', 'OK', 'SD', 'TN', 'TX', 'WI'],
    'America/Denver': ['CO', 'ID', 'MT', 'NM', 'UT', 'WY'],
    'America/Phoenix': ['AZ'],
    'America/Los_Angeles': ['CA', 'NV', 'OR', 'WA'],
    'America/Anchorage': ['AK'],
    'Pacific/Honolulu': ['HI'],
    'America/Puerto_Rico': ['PR']
};

const CA_PROVINCES = {
    'America/Toronto': ['ON', 'QC'],
    'America/Halifax': ['NS', 'NB', 'PE'],
    'America/St_Johns': ['NL'],
    'America/Winnipeg': ['MB'],
    'America/Regina': ['SK'],
    'America/Edmonton': ['AB', 'NT'],
    'America/Vancouver': ['BC'],
    'America/Whitehorse': ['YT'],
    'America/Iqaluit': ['NU']
};

const AU_STATES = {
    'Australia/Sydney': ['NSW', 'ACT', 'VIC', 'TAS'],
    'Australia/Brisbane': ['QLD'],
    'Australia/Adelaide': ['SA'],
    'Australia/Perth': ['WA'],
    'Australia/Darwin': ['NT']
};

const COUNTRIES = {
    GB: 'Europe/London', IE: 'Europe/Dublin', FR: 'Europe/Paris', DE: 'Europe/Berlin', NL: 'Europe/Amsterdam',
    BE: 'Europe/Brussels', LU: 'Europe/Luxembourg', ES: 'Europe/Madrid', PT: 'Europe/Lisbon', IT: 'Europe/Rome',
    CH: 'Europe/Zurich', AT: 'Europe/Vienna', DK: 'Europe/Copenhagen', SE: 'Europe/Stockholm', NO: 'Europe/Oslo',
    FI: 'Europe/Helsinki', PL: 'Europe/Warsaw', CZ: 'Europe/Prague', HU: 'Europe/Budapest', GR: 'Europe/Athens',
    RO: 'Europe/Bucharest', TR: 'Europe/Istanbul', IN: 'Asia/Kolkata', CN: 'Asia/Shanghai', HK: 'Asia/Hong_Kong',
    SG: 'Asia/Singapore', JP: 'Asia/Tokyo', KR: 'Asia/Seoul', AE: 'Asia/Dubai', ZA: 'Africa/Johannesburg',
    NZ: 'Pacific/Auckland', MX: 'America/Mexico_City'
};

const BY_REGION = { US: US_STATES, CA: CA_PROVINCES, AU: AU_STATES };

function invert(groups) {
    const lookup = {};
    Object.keys(groups).forEach((zone) => groups[zone].forEach((code) => {
        lookup[code] = zone;
    }));
    return lookup;
}

const REGION_LOOKUP = Object.fromEntries(Object.entries(BY_REGION).map(([country, groups]) => [country, invert(groups)]));

/**
 * @returns {{zone: string}|{missing: string}} the IANA zone, or why it cannot be worked out
 */
export function zoneFor(countryCode, stateCode) {
    const country = (countryCode || '').toUpperCase();
    if (!country) {
        return { missing: 'Add the Country to show the local time.' };
    }
    if (REGION_LOOKUP[country]) {
        const zone = REGION_LOOKUP[country][(stateCode || '').toUpperCase()];
        return zone ? { zone } : { missing: 'Add the State/Province to show the local time.' };
    }
    return COUNTRIES[country] ? { zone: COUNTRIES[country] } : { missing: 'Local time is not available for this country.' };
}

/** Minutes the zone is ahead of UTC at the given moment (negative when behind). */
export function offsetMinutes(zone, date) {
    const parts = new Intl.DateTimeFormat('en-US', {
        timeZone: zone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
        hour: '2-digit', minute: '2-digit', second: '2-digit'
    }).formatToParts(date).reduce((acc, part) => ({ ...acc, [part.type]: part.value }), {});
    const asUtc = Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day), Number(parts.hour) % 24,
        Number(parts.minute), Number(parts.second));
    return Math.round((asUtc - Math.floor(date.getTime() / 1000) * 1000) / 60000);
}

/** "5 hours ahead of you", "1 hour 30 minutes behind you", "the same time as you". */
export function differenceText(minutes) {
    if (minutes === 0) {
        return 'the same time as you';
    }
    const total = Math.abs(minutes);
    const hours = Math.floor(total / 60);
    const rest = total % 60;
    const pieces = [];
    if (hours) {
        pieces.push(hours + (hours === 1 ? ' hour' : ' hours'));
    }
    if (rest) {
        pieces.push(rest + (rest === 1 ? ' minute' : ' minutes'));
    }
    return pieces.join(' ') + (minutes > 0 ? ' ahead of you' : ' behind you');
}

/**
 * Short zone name such as EST, CDT, BST or CET. Browsers give US names in en-US and European ones in en-GB, and
 * "GMT-5" style offsets otherwise, so the first named form wins and the offset is the fallback.
 */
export function zoneAbbreviation(zone, date) {
    const names = ['en-US', 'en-GB'].map((locale) => new Intl.DateTimeFormat(locale, { timeZone: zone, timeZoneName: 'short' })
        .formatToParts(date).find((part) => part.type === 'timeZoneName')?.value);
    return names.find((name) => name && !/^(GMT|UTC)[+-]/.test(name)) || names[0];
}

/** Local time text for the Lead, or the reason it cannot be shown. */
export function localTimeFor(countryCode, stateCode, userZone, now, locale) {
    const found = zoneFor(countryCode, stateCode);
    if (found.missing) {
        return { text: found.missing, known: false };
    }
    const time = new Intl.DateTimeFormat(locale || 'en-GB', { timeZone: found.zone, hour: 'numeric', minute: '2-digit' })
        .format(now) + ' ' + zoneAbbreviation(found.zone, now);
    const difference = offsetMinutes(found.zone, now) - offsetMinutes(userZone, now);
    return { text: time + ' (' + differenceText(difference) + ')', known: true, zone: found.zone };
}
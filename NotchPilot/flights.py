"""Flight request details and outcome checks, separate from Jev's action policy."""
import base64
from datetime import date, timedelta
import re
from urllib.parse import urlsplit, parse_qs


def flight_route(text):
    match=re.search(r'\bflights?\s+from\s+(.+?)\s+to\s+(.+?)(?=\s+(?:depart(?:ing)?|leav(?:ing|e)|return(?:ing)?|on|for|in a new|in Google|and then)\b|[.;!?]|$)',text,re.I)
    return (match[1].strip(),match[2].strip()) if match else None


def requested_date(text,today):
    text=text.strip().lower()
    if text.startswith('today'): return today.isoformat()
    if text.startswith('tomorrow'): return (today+timedelta(days=1)).isoformat()
    found=re.match(r'(\d{4}-\d{2}-\d{2})\b',text)
    if found:
        try: return date.fromisoformat(found[1]).isoformat()
        except ValueError: return None
    months='january february march april may june july august september october november december'.split()
    match=re.match(r'([a-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?',text)
    if match:
        month=next((i for i,m in enumerate(months,1) if match[1] in (m,m[:3])),None)
        if month:
            try: return date(int(match[3] or today.year),month,int(match[2])).isoformat()
            except ValueError: pass
    return None


def prepare_flight(request,today=None):
    today=today or date.today()
    route=flight_route(request['goal'])
    if not route: return None
    answers=' '.join(turn['answer'] for turn in request.get('dialogue',[]))
    text=request['goal']+' '+answers
    depart_matches=list(re.finditer(r'\b(?:depart(?:ing|ure)?|leav(?:ing|e)|on)\s+',text,re.I))
    return_matches=list(re.finditer(r'\breturn(?:ing)?\s+',text,re.I))
    departure=requested_date(text[depart_matches[-1].end():],today) if depart_matches else None
    returning=requested_date(text[return_matches[-1].end():],today) if return_matches else None
    # A concise answer may contain two ISO dates without repeating the question.
    dates=re.findall(r'\b\d{4}-\d{2}-\d{2}\b',answers)
    if dates and not departure: departure=requested_date(dates[0],today)
    if len(dates)>1 and not returning: returning=requested_date(dates[1],today)
    one_way=bool(re.search(r'\bone[ -]way\b',text,re.I)) and not returning
    if not departure or (not returning and not one_way):
        return dict(action='clarify',goal='',question='What departure and return dates should I use, or is this one-way? You can say “depart today, return tomorrow” or give dates as YYYY-MM-DD. I’ll use one adult in economy unless you specify otherwise.')
    if date.fromisoformat(departure)<today or returning and returning<departure:
        return dict(action='clarify',goal='',question='Please give a departure date that has not passed and a return date on or after departure.')
    adults=re.search(r'\b(\d+)\s+adults?\b',text,re.I)
    cabin=re.search(r'\b(premium economy|business|first class|economy)\b',text,re.I)
    spec=dict(origin=route[0],destination=route[1],departure=departure,return_date=returning,
              adults=int(adults[1]) if adults else 1,cabin=cabin[1].lower() if cabin else 'economy')
    if not 1<=spec['adults']<=9: return dict(action='clarify',goal='',question='How many adults should I search for (1–9)?')
    goal=f"Find {'round-trip' if returning else 'one-way'} flights from {route[0]} to {route[1]} departing {departure}"
    if returning: goal+=' returning '+returning
    goal+=f" for {spec['adults']} adult(s) in {spec['cabin']}. Show matching flight options in a new Google Chrome tab."
    return dict(action='execute',goal=goal,question='',flight=spec)


def validate_spec(spec):
    keys={'origin','destination','departure','return_date','adults','cabin'}
    if not isinstance(spec,dict) or set(spec)!=keys: raise ValueError('Invalid flight details')
    if any(not isinstance(spec[k],str) or not 1<=len(spec[k])<=120 for k in ('origin','destination','departure','cabin')): raise ValueError('Invalid flight details')
    date.fromisoformat(spec['departure'])
    if spec['return_date'] is not None:
        date.fromisoformat(spec['return_date'])
        if spec['return_date']<spec['departure']: raise ValueError('Return precedes departure')
    if type(spec['adults'])!=int or not 1<=spec['adults']<=9: raise ValueError('Invalid traveler count')
    if spec['cabin'] not in ('economy','premium economy','business','first class'): raise ValueError('Invalid cabin')
    return spec


def place_matches(requested,observed):
    words=re.findall(r'[a-z0-9]+',requested.lower())
    # Airport names must survive; London alone does not prove Heathrow.
    words=[w for w in words if w not in ('airport','international','london') or len(words)==1]
    return bool(words) and all(w in observed.lower() for w in words)


def verify_flights(page,spec,aliases=None):
    spec=validate_spec(spec);parsed=urlsplit(page.get('url',''))
    values={a['label'].strip():str(a.get('value','')) for a in page.get('actions',[])}
    encoded=parse_qs(parsed.query).get('tfs',[''])[0]
    try: payload=base64.urlsafe_b64decode(encoded+'='*(-len(encoded)%4))
    except (ValueError,TypeError): payload=b''
    ticket='Round trip' if spec['return_date'] else 'One way'
    def short_date(iso):
        d=date.fromisoformat(iso)
        return d.strftime('%a, %b ')+str(d.day)
    labels=list(dict.fromkeys(a['label'] for a in page.get('actions',[]) if 'Select flight' in a['label']))
    departure=date.fromisoformat(spec['departure'])
    date_label=departure.strftime('%A, %B ')+str(departure.day)
    flights=[label for label in labels if re.search(r'[$£€]\s*[\d,]+|\b[\d,]+ (?:US dollars|British pounds|euros)\b',label,re.I)
             and date_label in label and place_matches(spec['origin'],label) and place_matches(spec['destination'],label)
             and len(re.findall(r'\b\d{1,2}:\d{2}\s*(?:AM|PM)',label))>=2 and 'flight with' in label.lower()]
    checks=dict(search_page=parsed.hostname=='www.google.com' and parsed.path=='/travel/flights/search',
                origin=place_matches(spec['origin'],values.get('Where from?','')) or values.get('Where from?','') in (aliases or {}).get(spec['origin'],set()),
                destination=place_matches(spec['destination'],values.get('Where to?','')) or values.get('Where to?','') in (aliases or {}).get(spec['destination'],set()),
                ticket=values.get('Change ticket type. '+ticket)==ticket,
                departure=values.get('Departure')==short_date(spec['departure']) and spec['departure'].encode() in payload,
                return_date=not spec['return_date'] or values.get('Return')==short_date(spec['return_date']) and spec['return_date'].encode() in payload,
                results=bool(flights))
    # Passenger/cabin controls vary in label; match actual observed control values.
    checks['cabin']=any(spec['cabin']==v.lower().removesuffix(' (include basic)') and ('cabin' in k.lower() or 'class' in k.lower()) for k,v in values.items())
    checks['adults']=any((str(spec['adults'])==v or re.search(r'\b'+str(spec['adults'])+r'\s+(?:passenger|adult)s?\b',k,re.I))
                         and ('passenger' in k.lower() or 'adult' in k.lower()) for k,v in values.items())
    return dict(passed=all(checks.values()),checks=checks,visible_flights=flights[:3],url=page.get('url',''))

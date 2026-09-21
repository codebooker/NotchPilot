"""Literal website navigation: no URL writer, guessed coordinates, or model calls."""
import re
import time
from urllib.parse import urlsplit, urlunsplit, urlencode, parse_qs

BROWSERS = {'safari': 'Safari', 'chrome': 'Google Chrome', 'google chrome': 'Google Chrome',
            'firefox': 'Firefox', 'edge': 'Microsoft Edge', 'microsoft edge': 'Microsoft Edge',
            'brave': 'Brave Browser', 'brave browser': 'Brave Browser', 'arc': 'Arc'}
URL_PATTERN = re.compile(r'(?<![\w@/.-])(?:https?://)?(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}(?::\d{1,5})?(?:[/?#][^\s<>"\x27]*)?', re.I)
FILE_SUFFIXES = {'txt','md','csv','pdf','docx','xlsx','json','py','swift','html','png','jpg','jpeg','zip','app'}


def browser_task(request):
    """Recognize a complete tab/search task, retaining the user's query verbatim.

    Do not turn a prefix of a larger workflow into a prematurely completed task.
    Dates, airports, qualifiers, and other search terms are opaque text here.
    """
    if '\n' in request: return None
    text=request.strip().rstrip('.!?').strip()
    text=re.sub(r'^(?:please|could you|can you|would you)\s+', '', text, flags=re.I)
    names='|'.join(re.escape(n) for n in sorted(BROWSERS,key=len,reverse=True))
    prefix=re.match(rf'^(?:open|create) (?:a )?new tab(?: in (?P<browser>{names}))?(?=$|[, ]+(?:and|then))',text,re.I)
    new_tab=bool(prefix); browser=BROWSERS.get(prefix['browser'].lower()) if prefix and prefix['browser'] else None
    if prefix:
        text=text[prefix.end():].strip()
        if not text: return dict(new_tab=True,browser=browser,query=None,url=None)
        connector=re.match(r'^,?\s*(?:and then|and|then)\s+',text,re.I)
        if not connector: return None
        text=text[connector.end():]
        direct=direct_navigation(text)
        if direct:
            if browser and direct['browser'] and browser!=direct['browser']: return None
            return dict(new_tab=True,browser=browser or direct['browser'],query=None,url=direct['url'])
    search=re.fullmatch(r'(?:search(?: the web)? for|search|find(?: me)?|look up)\s+(.+)',text,re.I)
    if not search: return None
    query=search[1].strip()
    # Bare 'find my file' is a desktop task; unqualified search/find without a
    # browser is only accepted for an explicit web-search verb or a new tab.
    suffix=re.search(rf'\s+in (?P<browser>{names})$',query,re.I)
    if suffix:
        specified=BROWSERS[suffix['browser'].lower()]
        if browser and browser!=specified: return None
        browser=specified;query=query[:suffix.start()].strip()
    if not new_tab and not browser and not re.match(r'^search\b',text,re.I): return None
    if not 1<=len(query)<=1500 or any(ord(c)<32 for c in query): return None
    if re.search(r'\b(?:then|afterwards|after that)\b|(?:\band\b|[;.!?])\s*(?:open|close|delete|send|book|buy|click|save|download|compare|summarize|tell|fill|sign|log|go|find|search)\b',query,re.I): return None
    return dict(new_tab=new_tab,browser=browser,query=query,url='https://www.google.com/search?'+urlencode({'q':query}))


def browser_tabs(pid):
    """Count exposed tabs in the focused window, without reading page contents."""
    import ApplicationServices as AS
    from typesafe_computer_use.macos import _ax_attr
    app=AS.AXUIElementCreateApplication(pid);AS.AXUIElementSetMessagingTimeout(app,.06)
    window=_ax_attr(app,'AXFocusedWindow')
    nodes=[window] if window is not None else [];count=0;deadline=time.monotonic()+1.5
    while nodes and count<300 and time.monotonic()<deadline:
        node=nodes.pop(0);count+=1
        role=_ax_attr(node,'AXRole')
        if role=='AXWebArea': continue
        children=list(_ax_attr(node,'AXChildren') or [])
        if role=='AXTabGroup':
            tabs=_ax_attr(node,'AXTabs')
            if tabs is None:
                tabs=[child for child in children if _ax_attr(child,'AXRole') in ('AXRadioButton','AXTab') or _ax_attr(child,'AXSubrole')=='AXTabButton']
            if tabs: return {'window':window,'count':len(tabs)}
        nodes.extend(children[:100])
    return None


def new_browser_tab(pid,front_pid):
    from typesafe_computer_use import macos
    before=browser_tabs(pid)
    if not before: raise RuntimeError('Could not read this browser window’s tabs. No tab was opened.')
    macos.check_abort()
    if front_pid()!=pid: raise RuntimeError('The active app changed before opening a tab.')
    button = new_tab_button(pid)
    if button is not None:
        if not macos.ax_press(button): raise RuntimeError('The browser refused its New Tab control.')
    else:
        macos.KEYCODES['t']=17;press_key('t',True)
    for _ in range(20):
        macos.check_abort()
        if front_pid()!=pid: raise RuntimeError('The active app changed while opening the tab.')
        after=browser_tabs(pid)
        if after and before['window']==after['window'] and after['count']==before['count']+1:
            return
        macos.sleep_watching(.1)
    detail = f" (tabs {before['count']} → {after['count']}, same window: {before['window']==after['window']})" if after else ''
    raise RuntimeError('Could not verify one new tab in the existing window'+detail+'. Search has not been submitted.')


def new_tab_button(pid):
    """Prefer the browser's declared action over synthetic keyboard input."""
    import ApplicationServices as AS
    from typesafe_computer_use.macos import _ax_attr, _ax_label
    app=AS.AXUIElementCreateApplication(pid);AS.AXUIElementSetMessagingTimeout(app,.06)
    window=_ax_attr(app,'AXFocusedWindow')
    nodes=[window] if window is not None else [];deadline=time.monotonic()+1
    while nodes and time.monotonic()<deadline:
        node=nodes.pop(0);role=_ax_attr(node,'AXRole')
        if role=='AXWebArea': continue
        if role=='AXButton' and _ax_label(node).strip().casefold()=='new tab': return node
        nodes.extend(list(_ax_attr(node,'AXChildren') or [])[:100])
    return None


def target_point(ref):
    from typesafe_computer_use.macos import _ax_frame
    frame=_ax_frame(ref) if ref is not None else None
    if frame and frame[2]>0 and frame[3]>0:
        return dict(x=frame[0]+frame[2]/2,y=frame[1]+frame[3]/2)
    return dict(x=None,y=None)


def search_result_matches(observed,query):
    try:
        parsed=urlsplit(observed)
        return parsed.scheme=='https' and parsed.hostname in ('www.google.com','google.com') and parsed.path=='/search' and parse_qs(parsed.query).get('q')==[query]
    except ValueError: return False


def spoken_dots(text):
    return re.sub(r'(?<=\w)\s+dot\s+(?=\w)', '.', text, flags=re.I)


def normalize_url(value):
    value = value.rstrip('.,!?')
    if any(c.isspace() for c in value) or '\\' in value or any(ord(c)<32 for c in value):
        raise ValueError('Invalid website address')
    parsed = urlsplit(value if '://' in value else 'https://' + value)
    if parsed.scheme not in ('http','https') or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError('Only HTTP or HTTPS websites are supported')
    if not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}', parsed.hostname, re.I):
        raise ValueError('Use a complete website domain')
    port = parsed.port  # Also rejects invalid ports.
    host = parsed.hostname.lower() + (f':{port}' if port else '')
    return urlunsplit((parsed.scheme,host,parsed.path or '/',parsed.query,parsed.fragment))


def urls_in(text):
    result=[]
    for match in URL_PATTERN.finditer(spoken_dots(text)):
        value=match[0].rstrip('.,!?')
        if '://' not in value and urlsplit('https://'+value).hostname.rsplit('.',1)[-1].lower() in FILE_SUFFIXES:
            continue
        try: result.append(normalize_url(value))
        except ValueError: pass
    return result


def without_urls(text):
    return URL_PATTERN.sub(lambda match: '' if urls_in(match[0]) else match[0], text)


def direct_navigation(goal, authorization=None):
    """Only a whole navigation request. Compound tasks stay with the controller."""
    text=spoken_dots(goal.strip())
    matches=list(URL_PATTERN.finditer(text))
    if len(matches)!=1: return None
    match=matches[0]
    try: url=normalize_url(match[0])
    except ValueError: return None
    if url not in urls_in(authorization if authorization is not None else goal): return None
    command=(text[:match.start()]+' WEBSITE '+text[match.end():]).lower().strip(' .!?')
    command=re.sub(r'\s+',' ',command)
    command=re.sub(r'^(?:please|could you|can you|would you|would you mind) ', '', command)
    command=re.sub(r'[, ]+please$', '', command)
    browser_names='|'.join(re.escape(n) for n in sorted(BROWSERS,key=len,reverse=True))
    action=r'(?:go to|navigate to|visit|open|take me to|browse to|load) (?:the (?:website|site) )?website'
    patterns=[rf'{action}(?: in (?P<browser>{browser_names}))?',
              rf'(?:open|launch) (?P<browser>{browser_names}) (?:and |then |and then ){action}',
              rf'in (?P<browser>{browser_names}),? {action}']
    for pattern in patterns:
        found=re.fullmatch(pattern,command)
        if found: return {'url':url,'browser':BROWSERS.get(found.group('browser'))}
    return None


def browser_url(pid):
    """Read the current window's web area; never use the editable address bar as proof."""
    import ApplicationServices as AS
    from typesafe_computer_use.macos import _ax_attr
    app=AS.AXUIElementCreateApplication(pid)
    AS.AXUIElementSetMessagingTimeout(app,.06)
    window=_ax_attr(app,'AXFocusedWindow')
    if window is None: return None
    nodes=[window]; count=0; deadline=time.monotonic()+1.2
    while nodes and count<180 and time.monotonic()<deadline:
        node=nodes.pop(0); count+=1
        if _ax_attr(node,'AXHidden'): continue
        if _ax_attr(node,'AXRole')=='AXWebArea':
            url=_ax_attr(node,'AXURL')
            if url:
                return str(url.absoluteString()) if hasattr(url,'absoluteString') else str(url)
        children=_ax_attr(node,'AXChildren')
        if children: nodes.extend(list(children)[:100])
    return None


def address_field(field):
    if not field or not field.is_text: return False
    if not re.search(r'address|search|website|location|url',field.label+' '+field.placeholder,re.I): return False
    # A web page search field must not be mistaken for the browser's toolbar.
    from typesafe_computer_use.macos import _ax_attr
    node=field.ref
    for _ in range(20):
        if node is None: return False
        role=_ax_attr(node,'AXRole')
        if role=='AXWebArea': return False
        if role in ('AXWindow','AXApplication'): return True
        node=_ax_attr(node,'AXParent')
    return False


def press_key(key,command=False,shift=False):
    """Set flags on every event; Return must not inherit Command from Command-L."""
    import Quartz
    from typesafe_computer_use import macos
    modifiers=(Quartz.kCGEventFlagMaskCommand if command else 0) | (Quartz.kCGEventFlagMaskShift if shift else 0)
    for down in (True,False):
        event=Quartz.CGEventCreateKeyboardEvent(None,macos.KEYCODES[key],down)
        Quartz.CGEventSetFlags(event,modifiers if down else 0)
        macos._post(event)


def dismiss_notification_prompt(pid):
    """Decline only a browser notification prompt, never grant site permissions."""
    import ApplicationServices as AS
    from typesafe_computer_use.macos import _ax_attr, _ax_label, ax_press
    app=AS.AXUIElementCreateApplication(pid);AS.AXUIElementSetMessagingTimeout(app,.04)
    windows=list(_ax_attr(app,'AXWindows') or [])
    focused=_ax_attr(app,'AXFocusedWindow')
    if focused is not None: windows.insert(0,focused)
    for window in windows[:8]:
        title=_ax_label(window)
        if not re.search(r'wants to.*show notifications',title,re.I): continue
        nodes=[window];count=0
        while nodes and count<60:
            node=nodes.pop(0);count+=1
            if _ax_attr(node,'AXRole')=='AXButton' and _ax_label(node)=='Block':
                if ax_press(node): return True
                return False
            nodes.extend(list(_ax_attr(node,'AXChildren') or [])[:30])
    return False


def browser_address_field(pid):
    """Find the browser's native address control without trusting system-wide focus."""
    import ApplicationServices as AS
    from typesafe_computer_use.macos import _ax_attr,_ax_frame
    from typesafe_computer_use.models import Field
    app=AS.AXUIElementCreateApplication(pid);AS.AXUIElementSetMessagingTimeout(app,.06)
    window=_ax_attr(app,'AXFocusedWindow')
    nodes=[window] if window is not None else [];matches=[];visited=0;deadline=time.monotonic()+1
    while nodes and visited<250 and time.monotonic()<deadline:
        node=nodes.pop(0);visited+=1;role=_ax_attr(node,'AXRole')
        if role=='AXWebArea':continue
        if role in ('AXTextField','AXComboBox'):
            value=_ax_attr(node,'AXValue');frame=_ax_frame(node) or (0,0,0,0)
            field=Field(role,str(_ax_attr(node,'AXTitle') or _ax_attr(node,'AXDescription') or ''),
                str(_ax_attr(node,'AXPlaceholderValue') or ''),value if isinstance(value,str) else '',*frame,ref=node)
            if address_field(field):matches.append(field)
        nodes.extend(list(_ax_attr(node,'AXChildren') or [])[:100])
    return matches[0] if len(matches)==1 else None


def navigate(url,pid,front_pid,search_query=None):
    from typesafe_computer_use import macos
    from typesafe_computer_use.actions import fill_field
    url=normalize_url(url)
    def check():
        macos.check_abort()
        if front_pid()!=pid: raise RuntimeError('The active app changed. Navigation stopped before typing.')
    check(); macos.KEYCODES['l']=37; press_key('l',True)
    field=None
    for _ in range(15):
        check(); field=browser_address_field(pid) or macos.focused_field()
        if address_field(field): break
        macos.sleep_watching(.1)
    else: raise RuntimeError('Could not identify the browser address bar. Please activate a browser window and try again.')
    check(); fill_field(field,url)
    current=browser_address_field(pid) or macos.focused_field(); check()
    if not address_field(current) or current.value.strip()!=url:
        raise RuntimeError('The address bar did not retain the requested URL. Navigation stopped.')
    press_key('return')
    deadline=time.monotonic()+12
    while time.monotonic()<deadline:
        if dismiss_notification_prompt(pid): macos.sleep_watching(.2)
        check(); observed=browser_url(pid)
        if observed:
            try:
                if search_query is not None:
                    if search_result_matches(observed,search_query): return True
                elif normalize_url(observed)==url: return True
            except ValueError: pass
        macos.sleep_watching(.2)
    return False

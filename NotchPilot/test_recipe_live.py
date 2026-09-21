"""Explicit paid live test of native Accessibility, never run by unittest."""
import json
from pathlib import Path
import sys

import worker


def main():
    root=Path(__file__).resolve().parents[1]
    # Any accidental introduction of CDP into this path fails the live test.
    for module in ('browser_harness','jev_ultrafast.browser','cdp_use'):
        sys.modules[module]=None
    events=[]
    def emit(event,**kw):
        entry={'event':event,**kw}; events.append(entry)
        print(json.dumps(entry),flush=True)
    worker.emit=emit
    worker.handshake=lambda event,**kw:emit(event,**kw)
    goal='Open a new tab in Google Chrome and find me a recipe for apple strudel'
    try:
        worker.run(root,goal,authorization=goal)
    finally:
        (root/'NotchPilot/build/recipe-live.json').write_text(json.dumps(events,indent=2)+'\n')


if __name__=='__main__':main()

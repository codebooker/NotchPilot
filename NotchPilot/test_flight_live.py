"""Explicit live runner; not a unittest. Makes paid Jev calls in an owned Chrome tab."""
import json
from pathlib import Path
from flights import prepare_flight
from worker import API
from browser_agent import run_flight_agent


def main():
    root=Path(__file__).resolve().parents[1]
    goal='Find a flight from Orlando to London Heathrow Airport departing 2026-09-21 returning 2026-09-22'
    plan=prepare_flight({'goal':goal})
    api=API(root,'openrouter',False)
    events=[]
    def emit(event,**kw):
        if event in ('done','status'):print(json.dumps({'event':event,**kw}),flush=True)
    def observe(state,page,check):
        last=state['history'][-1] if state['history'] else {}
        event={'status':state['status'],'action':last.get('action'),'operation':last.get('operation'),
               'text':last.get('text'),'checks':check['checks'],'cost':api.cost}
        events.append(event)
    try:
        result=run_flight_agent(root,plan['goal'],plan['flight'],api,emit,lambda *a,**k:None,on_state=observe)
        (root/'NotchPilot/build/flight-live.json').write_text(json.dumps({'events':events,'result':result,'cost':api.cost},indent=2))
    finally:api.client.close()


if __name__=='__main__':main()

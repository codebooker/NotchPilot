"""Locally authored synthetic evaluation; inference only, never submits forms.
Run with cua-s1 installed from a pinned upstream checkout, --model SAFETENSORS.
"""
import argparse, json, platform, statistics, time
from pathlib import Path
import torch
from cua_s1.model import load_checkpoint, ChoiceExample, parameter_count
from cua_s1.schema import Element, Entity, render_context, render_options


def cases():
    entities=[Entity('Full name','Alex Example'),Entity('First name','Alex'),Entity('Last name','Example'),
        Entity('Email','alex@example.invalid'),Entity('Street address','18 Fiction Lane'),
        Entity('City','Orlando'),Entity('State','FL'),Entity('Postal code','32801'),
        Entity('Phone','202-555-0141'),Entity('Emergency contact phone','202-555-0199'),
        Entity('Company','Sample Works'),Entity('Job title','Designer')]
    rows=[]
    for label,expected in [('Full name',0),('Your name',0),('First name',1),('Given name',1),('Last name',2),
        ('Surname',2),('Email address',3),('Contact email',3),('Street address',4),('Address line 1',4),
        ('City',5),('Town',5),('State',6),('Province',6),('ZIP code',7),('Postal code',7),
        ('Telephone',8),('Phone number',8),('Emergency contact phone',9),('Company',10),
        ('Organization',10),('Job title',11),('Occupation',11)]:
        rows.append(('empty',Element('Edit',label),expected))
        rows.append(('filled',Element('Edit',label,entities[expected].value),len(entities)+2))
    for label in ['Coupon code','Apartment number','Middle name','Fax number','Website','Search','Password']:
        rows.append(('missing',Element('Edit',label),len(entities)+2))
    for label in ['Cancel','Back','Help','Delete account']:
        rows.append(('navigation',Element('Button',label),len(entities)+2))
    rows.append(('submit',Element('Button','Submit'),len(entities)+1))
    rows.append(('checked',Element('CheckBox','Email me updates',checked=True),len(entities)+2))
    # Our user only supplied profile values: optional consent is not implied.
    rows.append(('optional_consent',Element('CheckBox','Subscribe to promotional emails',checked=False),len(entities)+2))
    return entities,rows


def main():
    p=argparse.ArgumentParser();p.add_argument('--model',type=Path,required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    torch.set_num_threads(4)
    start=time.perf_counter();model,collator,config=load_checkpoint(args.model,'cpu');load=time.perf_counter()-start
    entities,rows=cases();options=render_options(entities);results=[]
    with torch.inference_mode():
        warm=collator([ChoiceExample(render_context('Contact details',rows[0][1]),tuple(options),0)])
        model(warm)
        for category,element,expected in rows:
            context=render_context('Contact details',element)
            start=time.perf_counter();batch=collator([ChoiceExample(context,tuple(options),expected)])
            probs=model(batch).softmax(-1)[0].tolist();elapsed=time.perf_counter()-start
            predicted=max(range(len(probs)),key=probs.__getitem__)
            results.append(dict(category=category,label=element.label,value=element.value,expected=options[expected],
                predicted=options[predicted],correct=predicted==expected,confidence=probs[predicted],seconds=elapsed))
    summary={cat:dict(total=sum(r['category']==cat for r in results),correct=sum(r['category']==cat and r['correct'] for r in results)) for cat in sorted({r['category'] for r in results})}
    times=sorted(r['seconds'] for r in results)
    output=dict(scope='Independent fictional form decisions; no live execution, no fine tuning, CPU only',platform=platform.platform(),
        torch=torch.__version__,parameters=parameter_count(model),config=config,load_seconds=load,
        total=len(results),correct=sum(r['correct'] for r in results),median_ms=statistics.median(times)*1000,p95_ms=times[int(.95*(len(times)-1))]*1000,
        high_confidence_wrong=sum(not r['correct'] and r['confidence']>=.95 for r in results),by_category=summary,results=results)
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(output,indent=2)+'\n')
    print(json.dumps({k:v for k,v in output.items() if k not in ('results','config')},indent=2))
    for row in results:
        if not row['correct']:print('MISS',row['label'],':',row['predicted'],'expected',row['expected'],'confidence',round(row['confidence'],3))
if __name__=='__main__':main()

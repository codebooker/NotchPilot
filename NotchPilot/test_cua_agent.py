import json
import re
import copy
import asyncio
import plistlib
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx
import cua_agent as cua


class GroundingTests(unittest.TestCase):
    def setUp(self):self.snapshot={'elements':[{'element_token':'fresh','label':'6'}]}
    def choice(self,action,**kw):return {'action':action,'element_token':'fresh',**kw}
    def test_new_document_requirement_uses_original_instruction(self):
        self.assertTrue(cua.requires_new_document('Open TextEdit and create a new document. Type hello into it.'))
        self.assertFalse(cua.requires_new_document('Create a new document\nOriginal request: Edit the current document'))
    def test_explicit_stages_preserve_order_and_quoted_text(self):
        self.assertEqual(cua.command_steps('In Calculator, multiply 12 by 7, then open Safari.'),['In Calculator, multiply 12 by 7','open Safari.'])
        self.assertEqual(cua.command_steps('Open Finder and then open Calculator'),['Open Finder','open Calculator'])
        self.assertEqual(cua.command_steps('Type "first then second"'),['Type "first then second"'])
        self.assertEqual(cua.command_steps("Type 'first then second'"),["Type 'first then second'"])
    def test_calculator_verification_checks_expression_and_result(self):
        request=cua.arithmetic_request('In Calculator, multiply 12 by 7.')
        self.assertEqual(request['result'],'84')
        def snapshot(expression,result):return {'tree_markdown':f'- AXStaticText = "{expression}"\n- AXStaticText = "{result}"'}
        self.assertTrue(cua.calculator_verified(request,snapshot('12×7','84')))
        self.assertFalse(cua.calculator_verified(request,snapshot('112×7','784')))
        self.assertFalse(cua.calculator_verified(request,snapshot('14×6','84')))
        self.assertIsNone(cua.arithmetic_request('Type "multiply 12 by 7"'))
        self.assertIsNone(cua.arithmetic_request('Multiply 123456 by 789'))
    def test_real_cua_frame_shape_maps_to_screen_point(self):
        self.assertEqual(cua.cursor_point({'frame':{'x':342,'y':345,'w':48,'h':48}},{}),(366,369))
    def test_static_result_survives_compaction_and_apple_menu_is_removed(self):
        snapshot={'elements':[{'element_index':0,'element_token':'s:0','role':'AXWindow','label':'Calculator'},
            {'element_index':1,'element_token':'s:1','role':'AXMenuBarItem','label':'Apple'},
            {'element_index':2,'parent_index':1,'element_token':'s:2','role':'AXMenuItem','label':'Private recent file'}],
            'tree_markdown':'- [0] AXWindow "Calculator"\n  - AXStaticText = "42"\n- AXMenuBar'}
        compact=cua.model_snapshot(snapshot)
        self.assertIn('42',str(compact['visible_text']))
        self.assertNotIn('Private recent file',str(compact))
    def test_unobserved_tokens_cannot_act(self):
        with self.assertRaisesRegex(RuntimeError,'current window'):
            cua.action_args(self.choice('click',element_token='stale'),self.snapshot,10,20,'Click 6',False)
    def test_exact_window_is_always_bound(self):
        name,args=cua.action_args(self.choice('click'),self.snapshot,10,20,'Click 6',False)
        self.assertEqual((name,args['pid'],args['window_id'],args['element_token']),('click',10,20,'fresh'))
    def test_unsupported_shortcut_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError,'shortcut'):
            cua.action_args(self.choice('key',key='terminal_shell'),self.snapshot,10,20,'Open terminal',False)
    def test_shortcuts_use_exact_foreground_delivery_and_scroll_uses_supported_units(self):
        self.assertEqual(cua.action_args(self.choice('key',key='new_document'),self.snapshot,10,20,'New document',False)[1]['delivery_mode'],'foreground')
        _,args=cua.action_args(self.choice('scroll_down'),self.snapshot,10,20,'Scroll down',False)
        self.assertEqual((args['amount'],args['by'],args['window_id']),(1,'page',20))
    def test_app_menu_actions_use_foreground_delivery(self):
        self.snapshot['elements'][0]['role']='AXMenuItem'
        _,args=cua.action_args(self.choice('click'),self.snapshot,10,20,'New document',False)
        self.assertEqual(args['delivery_mode'],'foreground')
    def test_textedit_new_document_uses_observed_menu_item(self):
        snapshot={'app_name':'TextEdit','elements':[{'role':'AXMenuItem','label':'New','element_token':'new'}]}
        name,args=cua.action_args(self.choice('key',key='new_document',element_token=''),snapshot,10,20,'Create a new document',False)
        self.assertEqual((name,args['element_token']),('click','new'))
    def test_select_all_focuses_the_observed_editable_field(self):
        self.snapshot['elements'][0]['role']='AXTextArea'
        _,args=cua.action_args(self.choice('key',key='select_all'),self.snapshot,10,20,'Replace text',False)
        self.assertEqual(args['element_token'],'fresh')
        self.assertEqual(args['keys'],['cmd','a'])
    def test_text_generation_requires_setting_but_quoted_text_is_allowed(self):
        choice=self.choice('type',text='Hello there')
        with self.assertRaisesRegex(RuntimeError,'composition'):
            cua.action_args(choice,self.snapshot,10,20,'Write a greeting',False)
        self.assertEqual(cua.action_args(choice,self.snapshot,10,20,'Type Hello there',False)[1]['text'],'Hello there')
        self.assertEqual(cua.action_args(choice,self.snapshot,10,20,'Write a greeting',True)[0],'type_text')


class BatchTests(unittest.TestCase):
    def setUp(self):
        self.snapshot={'app_name':'Calculator','window_title':'Calculator','tree_markdown':'- AXStaticText = "6"',
            'elements':[{'element_token':'old','role':'AXButton','label':'7','enabled':True,'frame':{'x':1,'y':2,'w':10,'h':10}}]}
    def test_rebinds_to_fresh_token_only(self):
        plan=cua.prepare_clicks({'action':'click','following_clicks':['old']},self.snapshot)
        fresh=copy.deepcopy(self.snapshot);fresh['elements'][0]['element_token']='new'
        self.assertEqual(cua.next_click(plan[0],fresh)['element_token'],'new')
        fresh['elements'][0]['frame']['x']=30
        self.assertIsNone(cua.next_click(plan[0],fresh))
    def test_ambiguous_disabled_missing_and_excessive_plans_are_discarded(self):
        choice={'action':'click','following_clicks':['old']}
        for change in ('ambiguous','disabled','missing'):
            s=copy.deepcopy(self.snapshot)
            if change=='ambiguous':s['elements'].append({**s['elements'][0],'element_token':'other'})
            elif change=='disabled':s['elements'][0]['enabled']=False
            else:s['elements']=[]
            self.assertEqual(cua.prepare_clicks(choice,s),[])
        self.assertEqual(cua.prepare_clicks({**choice,'following_clicks':['old']*8},self.snapshot),[])
        self.assertEqual(cua.prepare_clicks({**choice,'action':'open_app'},self.snapshot),[])
    def test_dialog_new_content_and_moved_control_cancel_batch(self):
        initial=cua.batch_surface(self.snapshot)
        for change in ('dialog','content','moved','disabled'):
            s=copy.deepcopy(self.snapshot)
            if change=='dialog':s['window_title']='Confirm'
            elif change=='content':s['tree_markdown']+='\n- AXStaticText = "Error"'
            elif change=='moved':s['elements'][0]['frame']['y']=50
            else:s['elements'][0]['enabled']=False
            self.assertNotEqual(cua.batch_surface(s),initial)
    def test_model_view_keeps_app_controls_and_drops_menu_clutter(self):
        rows=[{'element_token':'s9:0','element_index':0,'role':'AXWindow','label':'Calculator'},
              {'element_token':'s9:1','element_index':1,'role':'AXButton','label':'6','enabled':True,'selected':False},
              {'element_token':'s9:2','element_index':2,'role':'AXButton','label':'Equals','enabled':False},
              {'element_token':'s9:3','element_index':3,'role':'AXMenuBarItem','label':'View'},
              {'element_token':'s9:4','element_index':4,'role':'AXMenu','label':'View','parent_index':3},
              {'element_token':'s9:5','element_index':5,'role':'AXMenuItem','label':'Scientific','parent_index':4,'selected':True},
              {'element_token':'s9:6','element_index':6,'role':'AXMenuItem','label':'Services'},
              {'element_token':'s9:7','element_index':7,'role':'AXMenu','label':'Services','parent_index':6},
              {'element_token':'s9:8','element_index':8,'role':'AXMenuItem','label':'Ask Claude','parent_index':7}]
        view,ids=cua.model_view({'app_name':'Calculator','window_title':'Calculator','elements':rows,'tree_markdown':'- AXStaticText = "42"'})
        self.assertEqual(view['controls'],[{'element_token':'1','role':'AXButton','label':'6'},
            {'element_token':'2','role':'AXButton','label':'Equals','enabled':False},
            {'element_token':'3','role':'AXMenuBarItem','label':'View'},
            {'element_token':'5','role':'AXMenuItem','label':'Scientific','selected':True}])
        self.assertEqual(view['visible_text'],['- AXStaticText = "42"'])
        self.assertEqual(ids,{'1':'s9:1','2':'s9:2','3':'s9:3','5':'s9:5'})
    def test_short_ids_map_back_to_snapshot_tokens(self):
        ids={'1':'s9:1','2':'s9:2'}
        choice=cua.restore_tokens({'action':'click','element_token':'1','following_clicks':['2','9']},ids)
        self.assertEqual(choice['element_token'],'s9:1')
        self.assertEqual(choice['following_clicks'],['s9:2','9'],'Unknown ids stay unknown and fail validation later')
        self.assertEqual(cua.restore_tokens({'action':'done','element_token':'','following_clicks':[]},ids)['element_token'],'')
    def test_static_context_is_in_the_cacheable_instructions(self):
        system=cua.system_prompt(['Calculator','Safari'])
        self.assertTrue(system.startswith(cua.INSTRUCTIONS))
        self.assertIn('"Calculator"',system);self.assertIn('select_all',system)
    def test_settings_offer_exactly_the_worker_models(self):
        source=''.join(path.read_text() for path in (Path(__file__).resolve().parent/'Sources').glob('*.swift'))
        block=source[source.index('enum ControllerModels'):];block=block[:block.index('\n}\n')]
        self.assertEqual(set(re.findall(r'"([a-z0-9-]+/[a-z0-9.-]+)"',block)),set(cua.MODELS))
    def test_numeric_display_changes_are_allowed_only_in_calculator(self):
        s=copy.deepcopy(self.snapshot);s['tree_markdown']='- AXStaticText = "42"'
        self.assertEqual(cua.batch_surface(self.snapshot),cua.batch_surface(s))
        s['tree_markdown']='- AXStaticText = "12×7"\n- AXStaticText = "84"'
        self.assertEqual(cua.batch_surface(self.snapshot),cua.batch_surface(s))
        s['tree_markdown']='- AXStaticText = "42"'
        s['app_name']=self.snapshot['app_name']='Browser'
        self.assertNotEqual(cua.batch_surface(self.snapshot),cua.batch_surface(s))
    def test_only_unambiguous_visible_window_is_selected(self):
        windows=[{'window_id':1,'title':'Calculator','is_on_screen':True},{'window_id':2,'title':'','is_on_screen':False}]
        self.assertEqual(cua.select_window(windows),1)
        windows.append({'window_id':3,'title':'Second document','is_on_screen':True})
        self.assertIsNone(cua.select_window(windows))
        windows[0]['z_index']=10;windows[2]['z_index']=11
        self.assertEqual(cua.select_window(windows),3)
        windows.append({'window_id':4,'title':'','app_name':'Finder','is_on_screen':True,'z_index':12,'bounds':{'width':500,'height':200}})
        self.assertEqual(cua.select_window(windows),4)
    def test_incomplete_response_is_not_treated_as_an_action(self):
        for content in ('',None,'{"action":','[]'):
            with self.assertRaisesRegex(RuntimeError,'incomplete decision'):
                cua.parse_decision({'choices':[{'message':{'content':content}}]})
        with self.assertRaisesRegex(RuntimeError,'response space'):
            cua.parse_decision({'choices':[{'finish_reason':'length','message':{'content':''}}]})
    def test_direct_open_requires_explicit_leading_request(self):
        catalog={'Calculator':{},'Safari':{}}
        for goal,expected in [('In Calculator, calculate 6 times 7.','Calculator'),
            ('Open Safari and go to example.com','Safari'),('Please launch Calculator.','Calculator')]:
            self.assertEqual(cua.initial_app(goal,catalog),expected)
        for goal in ('Do not open Calculator','Type Open Safari','Open Safari.app.zip',
                     'Find the Calculator documentation','Open Calculator\nOriginal request: Do not open Calculator'):
            self.assertIsNone(cua.initial_app(goal,catalog))
    def test_launch_uses_installed_bundle_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'Finder.app';(path/'Contents').mkdir(parents=True)
            (path/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.apple.finder'}))
            self.assertEqual(cua.launch_args({'name':'Finder','path':str(path)}),{'bundle_id':'com.apple.finder'})
    def test_hidden_menu_helpers_are_never_document_targets(self):
        windows=[{'window_id':13,'title':'','is_on_screen':False,'bounds':{'width':1470,'height':33}},
                 {'window_id':14,'title':'','is_on_screen':False,'bounds':{'width':500,'height':500}}]
        self.assertEqual(cua.document_windows(windows),[])
        self.assertIsNone(cua.select_window(windows))
        popup={'window_id':15,'title':'','app_name':'Google Chrome','is_on_screen':True,'bounds':{'width':500,'height':500}}
        self.assertEqual(cua.document_windows([popup]),[])


class ControllerTests(unittest.IsolatedAsyncioTestCase):
    async def scenario(self,decisions,preview=False,changed_surface=False,interrupt=False,recorded_calls=None,effect=None,new_document=False,goal_override=None,cancel_checkpoint=None,empty_observations=0,target=None,editable=False,framed=False,press_reply='continue',prestarted=False,run_id=None,model=None,log=None):
        calls=[] if recorded_calls is None else recorded_calls;events=[];requests=[];instances=[]
        class Driver:
            revision=0
            new_window=False
            async def __aenter__(self):instances.append(self);return self
            async def __aexit__(self,*args):calls.append(('closed',{}))
            async def call(self,tool_name,**args):
                name=tool_name
                calls.append((name,args))
                if name=='check_permissions':return {'accessibility':True}
                if name=='launch_app':return {'pid':10,'windows':[{'window_id':20,'title':'Calculator'}]}
                if name=='hotkey' and args.get('keys')==['cmd','n']:self.new_window=True
                if name=='list_windows' and new_document:
                    return {'windows':[{'window_id':20,'title':'Old document'}]+([{'window_id':21,'title':'New document'}] if self.new_window else [])}
                if name=='list_windows' and target:return {'windows':[{'window_id':20,'title':'Current document'}]}
                if name=='get_window_state':
                    self.revision+=1
                    if self.revision<=empty_observations:
                        return {'app_name':'Calculator','window_title':'Save','elements':[],'tree_markdown':''}
                    return {'app_name':'Calculator','window_title':'Calculator',
                        'tree_markdown':'- AXStaticText = "Unexpected dialog"' if changed_surface and self.revision>1 else '',
                        'elements':[{'element_token':f's{self.revision}','label':'6','role':'AXTextArea' if new_document or editable else 'AXButton',
                                     **({'frame':{'x':10,'y':20,'w':48,'h':48},'actions':['AXPress']} if framed else {})},
                                    {'element_token':f't{self.revision}','label':'7','role':'AXButton'}]}
                if name=='click':
                    if args['element_token'] not in (f's{self.revision}',f't{self.revision}'):raise RuntimeError('stale')
                    if interrupt:raise asyncio.CancelledError()
                    if effect:return {'effect':effect}
                return {}
        def handler(request):
            requests.append(request)
            choice={key:'' for key in cua.SCHEMA['required']};choice.update(window_id=0,following_clicks=[]);choice.update(decisions.pop(0))
            return httpx.Response(200,json={'choices':[{'message':{'content':json.dumps(choice)}}],'usage':{'cost':.001}})
        original=httpx.AsyncClient
        def client(**kw):return original(transport=httpx.MockTransport(handler),**kw)
        def handshake(event,**kw):
            events.append((event,kw))
            if event=='checkpoint' and sum(e=='checkpoint' for e,_ in events)==cancel_checkpoint:
                raise InterruptedError('Stopped while reviewing')
            if event=='host_key' and kw.get('key')=='n':instances[-1].new_window=True
            if event=='host_press':return press_reply
            return 'continue'
        with tempfile.TemporaryDirectory() as directory,patch.dict(os.environ,{'OPENROUTER_API_KEY':'fake'},clear=True),patch.object(cua,'Driver',Driver),patch('worker.apps',return_value={'0':{'name':'Calculator'}}),patch.object(cua.httpx,'AsyncClient',client):
            goal=goal_override or ('Create a new document and type 6' if new_document else 'Click 6 in Calculator')
            options={}
            if prestarted:
                warm=Driver();await warm.__aenter__();options['driver']=warm
            if run_id:options['run_id']=run_id
            if model:options['model']=model
            await cua.run(Path(directory),goal,lambda e,**kw:events.append((e,kw)),handshake,preview=preview,target=target,**options)
            if log is not None:
                path=Path(directory)/'.cache/notchpilot-performance.jsonl'
                log.extend(json.loads(line) for line in path.read_text().splitlines()) if path.exists() else None
        return calls,events,requests
    async def test_fronts_exact_window_and_reobserves_after_click_without_jev(self):
        calls,events,requests=await self.scenario([{'action':'open_app','app':'Calculator'},
            {'action':'click','element_token':'s1','reason':'Click 6'}, {'action':'done','reason':'Calculator shows 6'}])
        names=[name for name,_ in calls];index=names.index('click')
        self.assertEqual(names[index-1],'bring_to_front')
        self.assertIn('get_window_state',names[index+1:])
        self.assertTrue(events[-1][1]['success'])
        self.assertTrue(all(str(r.url).endswith('/chat/completions') for r in requests))
        self.assertTrue(all(json.loads(r.content)['model']==cua.MODEL for r in requests))
        self.assertEqual(calls[-1][0],'closed')
    async def test_existing_document_write_is_rejected_then_new_window_is_targeted(self):
        calls,_,requests=await self.scenario([{'action':'open_app','app':'Calculator'},
            {'action':'type','element_token':'s1','text':'6'},
            {'action':'key','key':'new_document'},
            {'action':'type','element_token':'s2','text':'6'},
            {'action':'done','reason':'Verified'}],new_document=True)
        writes=[args for name,args in calls if name=='type_text']
        self.assertEqual(len(writes),1)
        self.assertEqual(writes[0]['window_id'],21)
        state=json.loads(json.loads(requests[2].content)['messages'][1]['content'])
        self.assertFalse(state['recent_actions'][-1]['executed'])
    async def test_chain_advances_only_after_verified_stage_completion(self):
        calls,events,requests=await self.scenario([{'action':'done','reason':'Open'},
            {'action':'click','element_token':'s1'}, {'action':'done','reason':'6'}],
            goal_override='Open Calculator then click 6 in Calculator')
        states=[json.loads(json.loads(r.content)['messages'][1]['content']) for r in requests]
        self.assertEqual([s['goal'] for s in states],['Open Calculator','click 6 in Calculator','click 6 in Calculator'])
        self.assertEqual(states[1]['completed_stages'],['Open Calculator'])
        self.assertEqual(sum(e=='done' for e,_ in events),1)
    async def test_completion_without_observation_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError,'verify'):
            await self.scenario([{'action':'done','reason':'Trust me'}])
    async def test_followup_starts_in_exact_current_window_without_launching_app(self):
        calls,events,requests=await self.scenario([],goal_override='Write Hello world.',target={'app':'Calculator','pid':10,'window_id':20},editable=True)
        self.assertNotIn('launch_app',[name for name,_ in calls])
        self.assertTrue(events[-1][1]['success'])
        self.assertEqual(requests,[])
        self.assertTrue(all(args['window_id']==20 for name,args in calls if name=='get_window_state'))
        text_events=[fields for event,fields in events if event=='host_text']
        self.assertEqual(text_events[0]['text'],'Hello world.')
        self.assertNotIn('type_text',[name for name,_ in calls])
    async def test_closed_current_window_never_falls_back_to_other_document(self):
        calls=[]
        with self.assertRaisesRegex(RuntimeError,'closed or changed'):
            await self.scenario([],goal_override='Write Hello.',target={'app':'Calculator','pid':10,'window_id':99},recorded_calls=calls)
        self.assertNotIn('type_text',[name for name,_ in calls])
    async def test_dictation_preview_does_not_insert_text(self):
        _,events,requests=await self.scenario([],goal_override='Write Hello.',preview=True,
            target={'app':'Calculator','pid':10,'window_id':20},editable=True)
        self.assertFalse(events[-1][1]['success'])
        self.assertNotIn('host_text',[name for name,_ in events])
        self.assertEqual(requests,[])
    async def test_exact_dictation_uses_user_words_without_model_or_auto_spacing(self):
        _,events,requests=await self.scenario([],goal_override='Type exactly "Hello world."',
            target={'app':'Calculator','pid':10,'window_id':20},editable=True)
        event=next(fields for name,fields in events if name=='host_text')
        self.assertEqual(event['text'],'Hello world.')
        self.assertFalse(event['spacing'])
        self.assertEqual(requests,[])
    async def test_literal_dictation_does_not_select_all_existing_text(self):
        with self.assertRaisesRegex(RuntimeError,'before replacing text'):
            await self.scenario([{'action':'key','key':'select_all','element_token':'s1'}],
                goal_override='Write Hello.',target={'app':'Calculator','pid':10,'window_id':20})
    async def test_invalid_current_target_is_rejected(self):
        for target in ([],{'pid':True,'window_id':20},{'pid':10,'window_id':0}):
            with self.assertRaisesRegex(RuntimeError,'target is invalid'):
                await self.scenario([],goal_override='Write Hello.',target=target)
    async def test_explicit_different_app_overrides_current_window(self):
        calls,_,_=await self.scenario([{'action':'done','reason':'Opened'}],goal_override='Open Calculator',
            target={'app':'TextEdit','pid':11,'window_id':99})
        self.assertIn('launch_app',[name for name,_ in calls])
    async def test_transient_empty_window_is_reobserved_before_model_decision(self):
        calls,events,requests=await self.scenario([{'action':'click','element_token':'s2'},
            {'action':'done','reason':'Verified'}],goal_override='Open Calculator',empty_observations=1)
        self.assertTrue(events[-1][1]['success'])
        self.assertEqual(len(requests),2)
        self.assertEqual(sum(name=='get_window_state' for name,_ in calls),3)
    async def test_unreadable_window_stops_without_paying_for_repeated_decisions(self):
        calls=[]
        with self.assertRaisesRegex(RuntimeError,'controls are unavailable'):
            await self.scenario([],goal_override='Open Calculator',empty_observations=100,recorded_calls=calls)
        self.assertEqual(sum(name=='get_window_state' for name,_ in calls),3)
        self.assertFalse(any(name in ('click','type_text','press_key','hotkey') for name,_ in calls))
        self.assertEqual(calls[-1][0],'closed')
    async def test_read_only_window_text_is_sufficient_for_observation(self):
        class TextWindow:
            async def call(self,*args,**kwargs):
                return {'tree_markdown':'- AXStaticText = "Finished"','elements':[]}
        snapshot=await cua.observe_window(TextWindow(),10,20)
        self.assertIn('Finished',snapshot['tree_markdown'])
    async def test_chain_has_a_separate_step_allowance_for_each_stage(self):
        decisions=[]
        for _ in range(2):
            decisions.extend([{'action':'observe','window_id':20} for _ in range(14)])
            decisions.append({'action':'done','reason':'Verified stage'})
        _,events,_=await self.scenario(decisions,goal_override='Open Calculator then inspect Calculator')
        self.assertTrue(events[-1][1]['success'])
    async def test_single_stage_still_stops_at_its_step_limit(self):
        with self.assertRaisesRegex(RuntimeError,'step limit'):
            await self.scenario([{'action':'observe','window_id':20} for _ in range(30)],goal_override='Open Calculator')
    async def test_chain_cannot_spend_later_stages_allowances_on_a_stuck_stage(self):
        with self.assertRaisesRegex(RuntimeError,'part of the task reached its step limit'):
            await self.scenario([{'action':'observe','window_id':20} for _ in range(30)],
                                goal_override='Open Calculator then inspect Calculator')
    async def test_chain_total_step_limit_remains_bounded(self):
        decisions=[]
        for _ in range(5):
            decisions.extend([{'action':'observe','window_id':20} for _ in range(18)])
            decisions.append({'action':'done','reason':'Verified stage'})
        with self.assertRaisesRegex(RuntimeError,'task reached its step limit'):
            await self.scenario(decisions,goal_override='Open Calculator'+(' then inspect Calculator'*4))
    async def test_explicit_repeated_stages_do_not_trigger_loop_detection(self):
        decisions=[]
        for i in range(1,4):
            decisions.extend([{'action':'click','element_token':f's{i}'}, {'action':'done','reason':'Verified'}])
        _,events,_=await self.scenario(decisions,goal_override='In Calculator, click 6 then click 6 then click 6')
        self.assertTrue(events[-1][1]['success'])
    async def test_repeated_input_within_one_stage_still_stops(self):
        with self.assertRaisesRegex(RuntimeError,'repeating the same step'):
            await self.scenario([{'action':'click','element_token':f's{i}'} for i in range(1,4)],goal_override='Open Calculator')
    async def test_button_clicks_use_the_host_press_without_the_cua_wait(self):
        decisions=lambda:[{'action':'open_app','app':'Calculator'},{'action':'click','element_token':'s1','reason':'Click 6'},{'action':'done','reason':'Calculator shows 6'}]
        calls,events,_=await self.scenario(decisions(),framed=True)
        press=[fields for event,fields in events if event=='host_press']
        self.assertEqual(len(press),1)
        self.assertEqual(press[0]['press'],{'role':'AXButton','frame':{'x':10,'y':20,'w':48,'h':48},'label':'6'})
        self.assertEqual((press[0]['pid'],press[0]['window_id']),(10,20))
        self.assertNotIn('click',[name for name,_ in calls],'The host pressed it; Cua was not asked to click')
        self.assertGreater([name for name,_ in calls].count('get_window_state'),1,'The result is still observed afterwards')
    async def test_host_press_falls_back_to_cua_when_the_control_is_not_found(self):
        calls,events,_=await self.scenario([{'action':'open_app','app':'Calculator'},{'action':'click','element_token':'s1','reason':'Click 6'},
            {'action':'done','reason':'Calculator shows 6'}],framed=True,press_reply='fallback')
        self.assertEqual([name for name,_ in events].count('host_press'),1)
        self.assertEqual([name for name,_ in calls].count('click'),1)
    async def test_controls_without_press_or_frame_keep_the_cua_click(self):
        calls,events,_=await self.scenario([{'action':'open_app','app':'Calculator'},{'action':'click','element_token':'s1','reason':'Click 6'},
            {'action':'done','reason':'Calculator shows 6'}])
        self.assertNotIn('host_press',[name for name,_ in events])
        self.assertEqual([name for name,_ in calls].count('click'),1)
    async def test_prestarted_driver_is_used_and_left_to_its_owner(self):
        calls,events,_=await self.scenario([{'action':'open_app','app':'Calculator'},{'action':'done','reason':'Calculator is open'}],prestarted=True)
        self.assertNotIn(('closed',{}),calls,'A warm worker closes its own driver after the task')
        self.assertIn('launch_app',[name for name,_ in calls])
    async def test_timings_use_the_host_run_id(self):
        log=[]
        await self.scenario([{'action':'open_app','app':'Calculator'},{'action':'done','reason':'Calculator is open'}],run_id='host123',log=log)
        self.assertTrue(log and all(row['run']=='host123' for row in log))
    async def test_offered_models_only(self):
        _,_,requests=await self.scenario([{'action':'open_app','app':'Calculator'},{'action':'done','reason':'Calculator is open'}],model='deepseek/deepseek-v4-flash')
        self.assertEqual(json.loads(requests[0].content)['model'],'deepseek/deepseek-v4-flash')
        self.assertEqual(json.loads(requests[0].content)['provider'].get('require_parameters'),True,'Only providers that honor the output schema')
        self.assertEqual(json.loads(requests[0].content)['provider']['sort'],'latency','DeepSeek\'s cheapest provider took 12-15 s per decision')
        _,_,requests=await self.scenario([{'action':'open_app','app':'Calculator'},{'action':'done','reason':'Calculator is open'}],model='google/gemini-2.5-flash-lite')
        self.assertEqual(json.loads(requests[0].content)['provider']['sort'],'price','Other cheap choices use the cheapest provider')
        _,_,requests=await self.scenario([{'action':'open_app','app':'Calculator'},{'action':'done','reason':'Calculator is open'}])
        self.assertEqual(json.loads(requests[0].content)['provider']['sort'],'latency','The default keeps the fastest provider')
        with self.assertRaisesRegex(RuntimeError,'not offered'):
            await self.scenario([{'action':'done','reason':'x'}],model='someone/expensive-model')
    async def test_preview_does_not_launch_or_click(self):
        calls,events,_=await self.scenario([{'action':'open_app','app':'Calculator'}],preview=True)
        self.assertNotIn('launch_app',[name for name,_ in calls])
        self.assertFalse(events[-1][1]['success'])
    async def test_batch_reobserves_and_rebinds_without_an_extra_model_call(self):
        calls,events,requests=await self.scenario([{'action':'open_app','app':'Calculator'},
            {'action':'click','element_token':'s1','following_clicks':['t1']}, {'action':'done','reason':'Verified'}])
        self.assertEqual([args['element_token'] for name,args in calls if name=='click'],['s1','t2'])
        self.assertEqual(len(requests),3)
        self.assertEqual(sum(name=='get_window_state' for name,_ in calls),3)
    async def test_changed_surface_returns_to_model_before_following_click(self):
        calls,_,requests=await self.scenario([{'action':'open_app','app':'Calculator'},
            {'action':'click','element_token':'s1','following_clicks':['t1']}, {'action':'blocked','reason':'Unexpected dialog'}],changed_surface=True)
        self.assertEqual([args['element_token'] for name,args in calls if name=='click'],['s1'])
        self.assertEqual(len(requests),3)
    async def test_already_front_window_skips_reactivation(self):
        with patch.object(cua,'is_front_window',return_value=True):
            calls,_,_=await self.scenario([{'action':'open_app','app':'Calculator'},
                {'action':'click','element_token':'s1'}, {'action':'done','reason':'Verified'}])
        self.assertNotIn('bring_to_front',[name for name,_ in calls])
    async def test_cancellation_discards_following_clicks_and_closes_driver(self):
        calls=[]
        with self.assertRaises(asyncio.CancelledError):
            await self.scenario([{'action':'open_app','app':'Calculator'},
                {'action':'click','element_token':'s1','following_clicks':['t1']}],interrupt=True,recorded_calls=calls)
        self.assertEqual([args['element_token'] for name,args in calls if name=='click'],['s1'])
        self.assertEqual(calls[-1][0],'closed')
    async def test_cancel_at_review_boundary_prevents_next_batched_click(self):
        calls=[]
        with self.assertRaises(InterruptedError):
            await self.scenario([{'action':'open_app','app':'Calculator'},
                {'action':'click','element_token':'s1','following_clicks':['t1']}],
                cancel_checkpoint=3,recorded_calls=calls)
        self.assertEqual([args['element_token'] for name,args in calls if name=='click'],['s1'])
        self.assertEqual(calls[-1][0],'closed')
    async def test_history_records_executed_shortcut_even_without_a_reason(self):
        calls,events,requests=await self.scenario([{'action':'open_app','app':'Calculator'},
            {'action':'key','key':'new_tab','reason':''},{'action':'done','reason':'Verified'}])
        history=json.loads(json.loads(requests[-1].content)['messages'][1]['content'])['recent_actions']
        self.assertEqual(history[-1]['key'],'new_tab')
        self.assertTrue(history[-1]['executed'])
        host=[fields for event,fields in events if event=='host_key']
        self.assertEqual(len(host),1)
        self.assertEqual((host[0]['key'],host[0]['command'],host[0]['window_id']),('t',True,20))
        self.assertFalse(any(name in ('press_key','hotkey') for name,_ in calls))
    async def test_refused_or_partial_delivery_stops_the_sequence(self):
        for effect in ('refused','partial'):
            calls=[]
            with self.assertRaises(RuntimeError):
                await self.scenario([{'action':'open_app','app':'Calculator'},
                    {'action':'click','element_token':'s1','following_clicks':['t1']}],effect=effect,recorded_calls=calls)
            self.assertEqual(sum(name=='click' for name,_ in calls),1)
            self.assertEqual(calls[-1][0],'closed')
    async def test_noop_is_not_reported_as_executed(self):
        calls,_,requests=await self.scenario([{'action':'open_app','app':'Calculator'},
            {'action':'click','element_token':'s1','following_clicks':['t1']},{'action':'blocked','reason':'No change'}],effect='suspected_noop')
        history=json.loads(json.loads(requests[-1].content)['messages'][1]['content'])['recent_actions']
        self.assertFalse(history[-1]['executed'])
        self.assertEqual(sum(name=='click' for name,_ in calls),1)

if __name__=='__main__':unittest.main()

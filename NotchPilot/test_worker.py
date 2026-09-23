import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx
from worker import API,validate_choice
from contextlib import ExitStack
from types import SimpleNamespace


class ProviderTests(unittest.TestCase):
    def make_api(self,provider,writer=False):
        with tempfile.TemporaryDirectory() as d,patch.dict(os.environ,{
            'OPENROUTER_API_KEY':'fake-openrouter','TYPESAFE_API_KEY':'fake-typesafe'},clear=True):
            api=API(Path(d),provider,writer)
        return api

    def test_provider_routes_and_keys_are_separate(self):
        for provider,url,model,key in [
            ('typesafe','https://api.typesafe.ai/v1/systemone','jev-latest','fake-typesafe'),
            ('openrouter','https://openrouter.ai/api/alpha/decisions','~typesafe/jev-latest','fake-openrouter')]:
            api=self.make_api(provider);seen=[]
            def handle(request):
                seen.append(request)
                return httpx.Response(200,json={'usage':{'cost':.0001},'answers':{}})
            api.client.close();api.client=httpx.Client(transport=httpx.MockTransport(handle))
            api.call({'model':'~typesafe/jev-latest','state':{},'questions':{}})
            self.assertEqual(str(seen[0].url),url)
            self.assertEqual(seen[0].headers['Authorization'],'Bearer '+key)
            self.assertEqual(json.loads(seen[0].content)['model'],model)
            self.assertNotIn(key,seen[0].content.decode());api.client.close()

    def test_missing_native_key_never_falls_back(self):
        with tempfile.TemporaryDirectory() as d,patch.dict(os.environ,{'OPENROUTER_API_KEY':'fake'},clear=True):
            with self.assertRaisesRegex(RuntimeError,'TypeSafe'):API(Path(d),'typesafe')

    def test_keychain_override_precedes_project_file(self):
        with tempfile.TemporaryDirectory() as d,patch.dict(os.environ,{'NOTCHPILOT_TYPESAFE_API_KEY':'keychain-value'},clear=True):
            root=Path(d);(root/'.env').write_text('TYPESAFE_API_KEY=file-value\n')
            api=API(root,'typesafe');self.assertEqual(api.typesafe_key,'keychain-value');api.client.close()

    def test_writer_requires_explicit_enablement(self):
        api=self.make_api('typesafe')
        with self.assertRaisesRegex(RuntimeError,'Enable the optional'):api.call({},writer=True)
        api.client.close()

    def test_enabled_writer_uses_openrouter_even_for_native_decisions(self):
        api=self.make_api('typesafe',True);seen=[]
        def handle(request):
            seen.append(request);return httpx.Response(200,json={'usage':{'cost':.001}})
        api.client.close();api.client=httpx.Client(transport=httpx.MockTransport(handle))
        api.call({'model':'openai/gpt-5-mini'},writer=True)
        self.assertEqual(str(seen[0].url),'https://openrouter.ai/api/v1/chat/completions')
        self.assertEqual(seen[0].headers['Authorization'],'Bearer fake-openrouter');api.client.close()

    def test_error_does_not_retry_or_fallback(self):
        api=self.make_api('typesafe');seen=[]
        def handle(request):seen.append(request);return httpx.Response(401,json={})
        api.client.close();api.client=httpx.Client(transport=httpx.MockTransport(handle))
        with self.assertRaisesRegex(RuntimeError,'HTTP 401'):api.call({'model':'~typesafe/jev-latest'})
        self.assertEqual(len(seen),1);api.client.close()

    def test_unobserved_choices_and_invalid_confidence_are_rejected(self):
        for answer in [{'choice':'unseen','confidence':1},{'choice':'a','confidence':float('nan')},{'choice':'a','confidence':2}]:
            with self.assertRaises(ValueError):validate_choice(answer,{'a':'Available'})

    def test_stop_handshake_does_not_continue(self):
        import io
        from worker import handshake
        with patch('sys.stdin',io.StringIO('stop\n')),patch('sys.stdout',io.StringIO()):
            with self.assertRaises(InterruptedError):handshake('target',label='Save')


class DesktopContractTests(unittest.TestCase):
    def test_folder_fast_path_requires_an_explicit_existing_directory(self):
        from worker import literal_folder_request
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(literal_folder_request('Open Finder, then go to '+directory+'.'),Path(directory).resolve())
            for request in ['Do not open '+directory,'Open '+directory+' then delete it','Open /definitely-not-a-real-folder']:
                self.assertIsNone(literal_folder_request(request))
    def test_finder_verification_resolves_macos_file_reference_urls(self):
        from worker import finder_folder_verified
        from Foundation import NSURL
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory).resolve()
            reference=str(NSURL.fileURLWithPath_(str(path)).fileReferenceURL().absoluteString())
            attrs={('app','AXFocusedWindow'):'window',('window','AXTitle'):path.name,('window','AXDocument'):reference}
            with patch('ApplicationServices.AXUIElementCreateApplication',return_value='app'),patch('ApplicationServices.AXUIElementSetMessagingTimeout'), \
                 patch('typesafe_computer_use.macos._ax_attr',side_effect=lambda node,key:attrs.get((node,key))):
                self.assertTrue(finder_folder_verified(path,123))
    def test_literal_browser_chain_is_complete_and_keeps_requested_tabs(self):
        from worker import literal_browser_chain
        plans=literal_browser_chain('Open a new tab in Google Chrome and go to https://example.com/, then open another new tab in Google Chrome and go to https://example.org/.')
        self.assertEqual([p['url'] for p in plans],['https://example.com/','https://example.org/'])
        self.assertTrue(all(p['new_tab'] for p in plans))
        for goal in ['Open Chrome and find a flight','Go to example.com in Chrome then send an email',
                     'Open a new tab in Chrome and search for recipes','Type "go to example.com in Chrome"']:
            self.assertIsNone(literal_browser_chain(goal))
    def test_cua_routes_youtube_video_to_the_fast_verified_browser_path(self):
        from worker import run_cua_request
        import asyncio
        args=SimpleNamespace(root=Path('/unused'),preview=False,provider='openrouter',allow_writer=False,model='openai/gpt-5-mini')
        request={}
        goal='Open a new tab in Google Chrome and go to YouTube and find me a funny cat video'
        with patch('worker.run') as fast,patch('asyncio.to_thread',new_callable=AsyncMock) as thread:
            asyncio.run(run_cua_request(args,request,goal,[],goal))
        self.assertEqual(thread.call_args.args[0],fast)
        self.assertEqual(thread.call_args.args[2],goal)
    def test_capture_uses_app_acknowledgement_and_removes_temporary_image(self):
        from PIL import Image
        from worker import app_screenshot
        paths=[]
        def capture(event,**fields):
            self.assertEqual(event,'capture')
            path=Path(fields['path']);paths.append(path)
            self.assertFalse(path.exists())
            Image.new('RGBA',(20,10),(12,34,56,255)).save(path)
        with patch('worker.handshake',capture):image=app_screenshot()
        self.assertEqual(image.mode,'RGB')
        self.assertEqual(image.getpixel((0,0)),(12,34,56))
        self.assertFalse(paths[0].parent.exists())

    def test_cancelled_capture_does_not_read_a_stale_image(self):
        from worker import app_screenshot
        paths=[]
        def stop(event,**fields):
            paths.append(Path(fields['path']));raise InterruptedError('Stopped')
        with patch('worker.handshake',stop),self.assertRaises(InterruptedError):app_screenshot()
        self.assertFalse(paths[0].parent.exists())

    def test_finder_is_in_catalog(self):
        from worker import apps
        self.assertIn('/System/Library/CoreServices/Finder.app',[v['path'] for v in apps().values()])

    def test_system_apps_are_not_truncated_after_many_third_party_apps(self):
        from worker import apps
        def entries(root,pattern):
            if str(root)=='/Applications':return [root/f'Test{i:03}.app' for i in range(110)]
            if str(root)=='/System/Applications':return [root/'TextEdit.app']
            return []
        with patch.object(Path,'glob',entries):
            self.assertIn('TextEdit',[v['name'] for v in apps().values()])

    def test_real_upstream_state_contract_and_context(self):
        from PIL import Image
        from typesafe_computer_use.models import Screen,Item
        from typesafe_computer_use.decide import item_criteria
        from worker import decision_state
        screen=Screen(Image.new('RGB',(800,600)),1,'Finder',None,None)
        items=[Item(0,'Documents',1,20,30,100,80)]
        state=decision_state('Open it',screen,items,[],['Open Finder'])
        self.assertEqual(state['goal'],'Open it')
        self.assertEqual(state['earlier_session_commands'],['Open Finder'])
        self.assertIn('0',item_criteria(screen,items))

    def test_worker_open_finder_through_real_state_builder(self):
        import AppKit
        from PIL import Image
        from typesafe_computer_use.models import Screen,Item
        from typesafe_computer_use import macos
        from worker import run,apps
        finder=next(k for k,v in apps().items() if v['name']=='Finder')
        screens=[Screen(Image.new('RGB',(800,600)),1,name,None,None,pid=123)
                 for name in ['TextEdit','Finder']]
        items=[Item(0,'File',1,20,0,50,20)]
        app=SimpleNamespace(localizedName=lambda:'TextEdit',processIdentifier=lambda:123)
        workspace=SimpleNamespace(sharedWorkspace=lambda:SimpleNamespace(frontmostApplication=lambda:app))
        events=[]
        with ExitStack() as stack:
            for name in ['frontmost_app_and_pid','frontmost_app','browser_url','screenshot']:
                stack.enter_context(patch.object(macos,name,getattr(macos,name)))
            stack.enter_context(patch.dict(macos.KEYCODES,macos.KEYCODES.copy(),clear=True))
            stack.enter_context(patch.object(AppKit,'NSWorkspace',workspace))
            stack.enter_context(patch('worker.front_app',return_value=('TextEdit',123)))
            stack.enter_context(patch('Quartz.CGPreflightScreenCaptureAccess',return_value=True))
            stack.enter_context(patch.object(macos,'accessibility_trusted',return_value=True))
            stack.enter_context(patch.object(macos,'check_abort'))
            stack.enter_context(patch.object(macos,'sleep_watching'))
            stack.enter_context(patch('typesafe_computer_use.perception.capture',side_effect=screens))
            stack.enter_context(patch('typesafe_computer_use.perception.perceive',return_value=items))
            stack.enter_context(patch('worker.handshake'))
            stack.enter_context(patch('worker.exact_app',return_value=None))
            stack.enter_context(patch('worker.emit',side_effect=lambda event,**kw:events.append(dict(event=event,**kw))))
            opened=stack.enter_context(patch('worker.subprocess.run'))
            api=stack.enter_context(patch('worker.API')).return_value
            api.cost=0
            api.call.side_effect=[{'answers':{'kind':{'choice':'open_app','confidence':.99},'app':{'choice':finder,'confidence':.99}}},
                                  {'answers':{'kind':{'choice':'done','confidence':.99}}}]
            run(Path('/unused'),'Open Finder')
            opened.assert_called_once_with(['/usr/bin/open','/System/Library/CoreServices/Finder.app'],check=True,capture_output=True)
            self.assertTrue(events[-1]['success'])
            self.assertEqual(api.call.call_count,2)
            self.assertEqual(api.call.call_args_list[0].args[0]['state']['goal'],'Open Finder')

    def test_direct_app_match_rejects_extra_instructions_and_ambiguity(self):
        from worker import exact_app
        finder={'name':'Finder','path':'/System/Library/CoreServices/Finder.app'}
        catalog={'0':finder}
        for goal in ['Open Finder','Open the Finder.','Launch Finder app','Switch to Finder']:
            self.assertEqual(exact_app(goal,catalog),finder)
        for goal in ['Open Finder and delete the folder','Do not open Finder','Open nonexistent','Open Finder then save']:
            self.assertIsNone(exact_app(goal,catalog))
        self.assertIsNone(exact_app('Open Finder',{'0':finder,'1':finder}))

    def test_direct_app_verifies_foreground_and_respects_preview(self):
        from worker import open_exact_app
        finder={'name':'Finder','path':'/System/Library/CoreServices/Finder.app'}
        with patch('worker.handshake'),patch('worker.subprocess.run') as opened,patch('worker.emit') as emit:
            open_exact_app(finder,True,lambda:finder['path'])
            opened.assert_not_called()
            self.assertFalse(emit.call_args.kwargs['success'])
            open_exact_app(finder,False,lambda:finder['path'])
            opened.assert_called_once()
            self.assertTrue(emit.call_args.kwargs['success'])


if __name__=='__main__':unittest.main()

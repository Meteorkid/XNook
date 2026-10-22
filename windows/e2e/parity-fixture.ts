import type { Page } from '@playwright/test';

export const reminderCalendar = (title = '课程讨论', uid = 'meeting') => `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:${uid}\r\nDTSTART:20261017T020400Z\r\nDTEND:20261017T030000Z\r\nSUMMARY:${title}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n`;

/** 只模拟原生边界；不安装软件、不操作真实剪贴板/文件或 Windows 登录项。 */
export async function installParityFixture(page: Page, options: {settings?: Record<string, unknown>; corrupt?: boolean; store?: Record<string,unknown>; failLyrics?:boolean; memoryStore?:boolean} = {}) {
  await page.addInitScript(({ settings, corrupt, calendar, store, failLyrics, memoryStore }) => {
    const runtime = window as any;
    const callbacks = new Map<number, (event: unknown) => void>();
    const listeners = new Map<string, number[]>(); let next = 1;
    const empty = { version:1, notes:[], files:[], calendars:[], activeSession:null, history:[], remindedEvents:[],
      ...store, settings:{ followPointer:true, hideInFullscreen:true, lyricsEnabled:true, preferredMediaSourceId:null, idleCollapseMs:0, ...settings } };
    const initialContent = corrupt ? '{broken original' : JSON.stringify(empty);
    if (!memoryStore && localStorage.getItem('parity-store') === null) localStorage.setItem('parity-store', initialContent);
    const state = {
      calls:[] as Array<{command:string;args:any}>, login:false, failSound:false, failRead:false, failWrite:false, failVirtualDesktop:false, failLyrics, playing:true,
      unavailablePaths:[] as string[], trayActions:[] as string[], statusGate:null as null|Promise<void>,
      content: memoryStore ? initialContent : localStorage.getItem('parity-store'), memoryStore,
      preferenceGate:null as null|Promise<void>, writeGate:null as null|Promise<void>,
      exitState:'idle' as 'idle'|'saving'|'confirming'|'authorized', nativeForceDialogs:0,
      calendarText:calendar, backup:null as string|null, gifs:[] as Array<{id:string;name:string}>,
      shared:{swipeEnabled:true,sensitivity:'medium',startupDisplay:'lastUsed'},
      update:{currentVersion:'0.3.1',latestVersion:null,updateAvailable:false,url:null,checkedAt:new Date().toISOString(),message:'暂无 Windows 更新'},
      emit(event:string,payload:unknown=null) { if(event==='request-exit'&&state.exitState==='idle')state.exitState='saving'; for(const id of listeners.get(event)||[]) callbacks.get(id)?.({event,id,payload}); },
      requestExit() { if(state.exitState==='idle'){state.exitState='saving';state.emit('request-exit');}else if(state.exitState==='saving'){state.exitState='confirming';state.nativeForceDialogs++;} },
      resolveForce(confirmed:boolean) { if(state.exitState==='confirming')state.exitState=confirmed?'authorized':'idle'; },
    };
    runtime.__parity=state;runtime.isTauri=true;
    runtime.__TAURI_EVENT_PLUGIN_INTERNALS__={unregisterListener(){}};
    runtime.__TAURI_INTERNALS__={
      metadata:{currentWindow:{label:'main'},currentWebview:{label:'main'}},
      transformCallback(fn:(event:unknown)=>void){const id=next++;callbacks.set(id,fn);return id;},
      unregisterCallback(id:number){callbacks.delete(id);},
      async invoke(command:string,args:any={}) {
        state.calls.push({command,args});
        if(command==='plugin:event|listen'){listeners.set(args.event,[...(listeners.get(args.event)||[]),args.handler]);return args.handler;}
        if(command==='plugin:event|unlisten')return null;
        if(command==='take_tray_actions')return state.trayActions.splice(0);
        if(command==='file_statuses'){if(state.statusGate)await state.statusGate;return args.paths.map((path:string)=>({path,available:!state.unavailablePaths.includes(path),error:state.unavailablePaths.includes(path)?'测试磁盘未连接':null,sizeBytes:2048,isDirectory:false}));}
        if(command==='read_store')return state.memoryStore?state.content:localStorage.getItem('parity-store');
        if(command==='write_store'){if(state.writeGate)await state.writeGate;if(state.failWrite)throw new Error('测试磁盘不可写');state.content=args.content;if(!state.memoryStore)localStorage.setItem('parity-store',args.content);return null;}
        if(command==='recover_store'){state.backup=localStorage.getItem('parity-store');localStorage.setItem('parity-store',args.content);return {backupPath:'C:\\XNook\\store-backup.json'};}
        if(command==='apply_preferences'){if(state.preferenceGate)await state.preferenceGate;if(state.failVirtualDesktop&&args.settings.visibleOnAllDesktops)throw new Error('测试系统不支持虚拟桌面驻留');return null;}
        if(command==='begin_exit'){state.requestExit();return null;}
        if(command==='cancel_exit'){if(state.exitState==='saving'||state.exitState==='idle'){state.exitState='idle';return null;}throw new Error('原生退出确认尚未结束');}
        if(command==='confirm_exit'){if(state.exitState!=='saving')throw new Error('没有待确认的退出请求，或原生退出确认尚未结束');state.exitState='authorized';return null;}
        if(command==='get_launch_at_login')return state.login;
        if(command==='set_launch_at_login'){state.login=args.enabled;return state.login;}
        if(command==='island_get_preferences')return structuredClone(state.shared);
        if(command==='island_set_preferences'){state.shared=structuredClone(args.preferences);return structuredClone(state.shared);}
        if(command==='island_peer_status')return {installed:true,running:true,compatible:true,detail:'测试对方已就绪'};
        if(command==='media_snapshot')return {available:true,sourceId:'cloudmusic.exe',sessionToken:'11111111-1111-4111-8111-111111111111',playerName:'网易云音乐',playerKind:'netease',
          sources:[{sourceId:'cloudmusic.exe',name:'网易云音乐',kind:'netease',playing:true,isSystemCurrent:true}],
          title:'音乐',artist:'测试歌手',album:'测试专辑',playing:state.playing,position:12,duration:180,artwork:null,
          canPlayPause:true,canPrevious:true,canNext:true,canSeek:true,sampledAt:Date.now()};
        if(command==='lookup_lyrics'){if(state.failLyrics)throw new Error('Network connection failed');return [{id:1,trackName:'音乐',artistName:'测试歌手',albumName:'测试专辑',duration:180,instrumental:false,syncedLyrics:'[00:00.00]第一句\n[00:10.00]正在播放的歌词',plainLyrics:'第一句\n正在播放的歌词'}];}
        if(command==='media_control'){if(args.action==='toggle')state.playing=!state.playing;return null;}
        if(command==='pick_files')return [{path:'C:\\资料\\课程.pdf',name:'课程.pdf',isDirectory:false}];
        if(command==='inspect_files')return args.paths.map((path:string)=>({path,name:path.split(/[\\/]/).at(-1),isDirectory:false}));
        if(command==='pick_calendar'||command==='read_calendar'){if(state.failRead)throw new Error('测试日历磁盘断开');return {path:'C:\\资料\\日程.ics',name:'日程.ics',content:state.calendarText};}
        if(command==='play_reminder_sound'){if(state.failSound)throw new Error('测试声音设备失败');return null;}
        if(command==='list_gifs')return structuredClone(state.gifs);
        if(command==='import_gif'){const gif={id:'22222222-2222-4222-8222-222222222222',name:'测试动画.gif'};state.gifs=[gif];return gif;}
        if(command==='read_gif')return 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
        if(command==='delete_gif'){state.gifs=state.gifs.filter(gif=>gif.id!==args.id);return null;}
        if(command==='check_updates')return structuredClone(state.update);
        if(['resize_island','configure_window','focus_input','drag_island','open_file','reveal_file','copy_files','start_file_drag','open_media_player','open_calendar','open_update_page','switch_island','confirm_exit','media_control'].includes(command))return null;
        throw new Error(`未约定的原生命令：${command}`);
      },
    };
  }, { settings:options.settings||{}, corrupt:options.corrupt||false, calendar:reminderCalendar(), store:options.store||{}, failLyrics:options.failLyrics||false, memoryStore:options.memoryStore||false });
}

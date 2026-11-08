import { test, eq, ok } from './harness.mjs';
import { pingRead } from '../../web/js/pages/poste.js';
import { setToastImpl } from '../../web/js/ui.js';

test('Poste réel : le résultat du ping distingue réponse, silence ICMP et présence inconnue', async () => {
  const notices=[];
  setToastImpl((text,options)=>notices.push({text,...options}));
  try {
    for(const [answered,source,roundTripMs] of [
      [null,'Nom du poste non résolu ; aucun test ICMP envoyé, présence inconnue.',null],
      [null,'Le transport réseau n’a pas permis le test ICMP ; présence inconnue.',null],
      [null,'Budget du test ICMP dépassé ; présence non confirmée.',null],
      [null,'',null],
      [false,'Aucune réponse ICMP reçue.',null],
      [true,'Réponse ICMP reçue.',0],
      [true,'Réponse ICMP reçue.',12],
    ]) {
      notices.length=0;
      const calls=[],busy=[];let reloads=0;
      const dn='CN=PC-TEST,OU=Postes,DC=example,DC=local';
      const state={dn,data:{computer:{name:'PC-TEST'}},bar:{setBusy:(...args)=>busy.push(args)},
        call:async(operation,args)=>{calls.push({operation,args});return {answered,source,roundTripMs};},
        reload:async()=>{reloads++;}};
      await pingRead(document.createElement('main'),state);
      eq(calls,[{operation:'poste.ping',args:{dn}}],'un seul appel au poste explicitement choisi');
      eq(reloads,1,'projection locale relue après le résultat');
      eq(busy,[['ping',true],['ping',false]],'commande libérée après le traitement');
      eq(notices.length,1,'un seul résultat présenté');
      eq(notices[0].tone,answered===true?'ok':'warn','une présence inconnue n’est jamais un succès');
      if(answered===null){
        ok(notices[0].text.includes(source||'présence inconnue'),'diagnostic conservé ou inconnu explicite');
        ok(!notices[0].text.includes('ne répond pas'),'une erreur ne devient pas un silence ICMP');
      }else if(answered===false){
        ok(notices[0].text.includes('ne répond pas au ping'),'silence ICMP achevé dit précisément');
        ok(notices[0].text.includes('pas une preuve'),'aucun verdict de poste éteint');
      }else{
        ok(notices[0].text.includes('répond au ping'),'réponse positive dite');
        if(roundTripMs>0)ok(notices[0].text.includes('12'),'latence connue conservée');
      }
      ok(!/\b0\s*ms\b/.test(notices[0].text),'aucune latence zéro inventée');
    }
  } finally {setToastImpl(null);}
});

test('Poste réel : refus du ping conserve l’erreur et libère la commande sans relire un faux résultat', async () => {
  const notices=[],busy=[];let reloads=0;
  setToastImpl((text,options)=>notices.push({text,...options}));
  try {
    await pingRead(document.createElement('main'),{dn:'CN=PC-TEST,DC=example,DC=local',data:{computer:{name:'PC-TEST'}},
      bar:{setBusy:(...args)=>busy.push(args)},
      call:async()=>{throw Object.assign(new Error('Identité du poste non vérifiée.'),{code:'source.unavailable'});},
      reload:async()=>{reloads++;}});
    eq(notices,[{text:'Identité du poste non vérifiée.',tone:'warn'}],'refus moteur conservé');
    eq(reloads,0,'aucun nouveau résultat supposé');
    eq(busy,[['ping',true],['ping',false]],'commande libérée même après refus');
  } finally {setToastImpl(null);}
});

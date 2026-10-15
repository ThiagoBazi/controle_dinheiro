async function resetPassword(){
 const email=authEmail.value.trim();if(!email)return alert('Informe seu e-mail.');
 const {error}=await sb.auth.resetPasswordForEmail(email,{redirectTo:location.origin+location.pathname});
 alert(error?'Não foi possível solicitar a recuperação.':'Se o e-mail estiver cadastrado, você receberá as instruções.');
}
async function updatePassword(){
 const password=document.getElementById('newPassword').value;
 if(password.length<10)return alert('Use pelo menos 10 caracteres.');
 const {error}=await sb.auth.updateUser({password});if(error)return alert(error.message);
 closeModal();alert('Senha atualizada.');
}
async function billing(action){
 const {data,error}=await sb.functions.invoke('billing',{body:{action}});
 if(error||data?.error)throw new Error(data?.error||'Serviço indisponível. Tente novamente.');return data;
}
let billingBusy=false;
async function subscribePlan(){
 if(billingBusy)return;billingBusy=true;
 try{const r=await billing('checkout');const url=new URL(r.url);if(url.protocol!=='https:'||!(url.hostname==='mercadopago.com.br'||url.hostname.endsWith('.mercadopago.com.br')))throw new Error('Endereço de pagamento inválido');location.assign(url.href);}
 catch(e){alert(e.message);}finally{billingBusy=false;}
}
async function cancelPlan(){
 if(!confirm('Cancelar a renovação? O período já pago continuará disponível.'))return;
 try{await billing('cancel');await openAccount();}catch(e){alert(e.message);}
}
async function refreshPlan(){try{await billing('refresh');await openAccount();}catch(e){alert(e.message);}}
async function openAccount(){
 if(!household)return;
 const {data:s,error}=await sb.from('subscriptions').select('status,trial_until,paid_until').eq('household_id',household.id).single();
 if(error)return alert('Não foi possível carregar a assinatura.');
 const until=new Date(Math.max(Date.parse(s.trial_until)||0,Date.parse(s.paid_until)||0));
 const active=until>new Date();
 openModal('Minha assinatura',`<p>Plano casal · ${escapeHtml(APP_CONFIG.priceLabel)}</p><p>${active?'Acesso disponível até '+until.toLocaleDateString('pt-BR'):'Período encerrado. Seus dados continuam disponíveis para consulta e exportação.'}</p><p>Renovação: ${escapeHtml(({trial:'teste',pending:'aguardando autorização',authorized:'autorizada',paused:'pausada',cancelled:'cancelada'})[s.status]||s.status)}</p><p>Uma assinatura atende as duas pessoas. Apenas o titular gerencia os pagamentos.</p><div class="sheet-actions"><button class="btn primary" onclick="subscribePlan()">Assinar</button><button class="btn light" onclick="refreshPlan()">Atualizar pagamento</button><button class="btn light" onclick="cancelPlan()">Cancelar renovação</button></div><p><button class="mini" onclick="exportData()">Exportar todos os dados</button></p><p><a href="./termos.html" target="_blank">Termos</a> · <a href="./privacidade.html" target="_blank">Privacidade</a></p><p>${APP_CONFIG.supportEmail?'Suporte: '+escapeHtml(APP_CONFIG.supportEmail):'Contato de suporte ainda não configurado.'}</p>`);
}
async function exportData(){
 try{
 const result={exported_at:new Date().toISOString(),household};
 for(const table of ['household_members','member_settings','extra_income','expenses','pending_items']){
  result[table]=[];let offset=0;
  while(true){
   let query=sb.from(table).select('*').eq('household_id',household.id);
   query=table==='member_settings'?query.order('user_id').order('month'):table==='household_members'?query.order('user_id'):query.order('id');
   const {data:rows,error}=await query.range(offset,offset+499);if(error)throw error;
   result[table].push(...rows);if(rows.length<500)break;offset+=500;
  }
 }
 const url=URL.createObjectURL(new Blob([JSON.stringify(result,null,2)],{type:'application/json'}));
 const a=document.createElement('a');a.href=url;a.download='meu-dinheiro-dados.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
 }catch(e){alert('Não foi possível exportar. Tente novamente.');}
}

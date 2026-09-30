-- Sistema de clínica de estética | Supabase (Postgres) | rode no SQL Editor
create extension if not exists btree_gist;

-- PERFIS, UNIDADES E USUÁRIOS -------------------------------------------
create table perfis (id text primary key, nome text not null);
insert into perfis values ('admin','Administração'),('profissional','Profissional');

create table unidades (
  id uuid primary key default gen_random_uuid(),
  nome text not null, endereco text, telefone text, cnpj text,
  cor text not null default '#C4677F',
  google_calendar_id text,
  horario_funcionamento jsonb not null default '{}',
  ativa boolean not null default true,
  criada_em timestamptz not null default now()
);
create table usuarios (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null,
  perfil text not null default 'profissional' references perfis(id),
  ativo boolean not null default true
);
create table usuario_unidades (
  usuario_id uuid references usuarios(id) on delete cascade,
  unidade_id uuid references unidades(id) on delete cascade,
  primary key (usuario_id, unidade_id)
);

-- CLIENTES E SERVIÇOS ---------------------------------------------------
create table clientes (
  id uuid primary key default gen_random_uuid(),
  nome text not null, telefone text, email text, nascimento date, observacoes text,
  criado_em timestamptz not null default now()
);
create table servicos (
  id uuid primary key default gen_random_uuid(),
  nome text not null, preco numeric(10,2) not null default 0,
  duracao_min int not null default 60, ativo boolean not null default true
);

-- AGENDA (uma só, com cor por unidade; sem choque de horário por profissional)
create table agendamentos (
  id uuid primary key default gen_random_uuid(),
  unidade_id uuid not null references unidades(id),
  cliente_id uuid not null references clientes(id),
  profissional_id uuid not null references usuarios(id),
  servico_id uuid not null references servicos(id),
  inicio timestamptz not null, fim timestamptz not null,
  status text not null default 'agendado'
    check (status in ('agendado','confirmado','concluido','cancelado','faltou')),
  observacoes text, google_event_id text,
  check (fim > inicio),
  exclude using gist (profissional_id with =, tstzrange(inicio, fim) with &&)
    where (status not in ('cancelado','faltou'))
);

-- PAGAMENTOS E CONTAS A RECEBER (parcelas em qualquer forma de pagamento)
create table formas_pagamento (
  id uuid primary key default gen_random_uuid(),
  nome text not null, taxa_percentual numeric(5,2) not null default 0,
  dias_para_receber int not null default 0, ativa boolean not null default true
);
insert into formas_pagamento (nome, taxa_percentual, dias_para_receber) values
  ('Pix',0,0),('Dinheiro',0,0),('Cartão de débito',0,1),('Cartão de crédito',0,30);

create table pacotes (
  id uuid primary key default gen_random_uuid(),
  nome text not null, servico_id uuid references servicos(id),
  sessoes int not null, preco numeric(10,2) not null,
  validade_dias int, ativo boolean not null default true
);
create table pacotes_cliente (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id),
  pacote_id uuid not null references pacotes(id),
  sessoes_restantes int not null,
  comprado_em date not null default current_date, expira_em date
);
create table contas_receber (
  id uuid primary key default gen_random_uuid(),
  unidade_id uuid not null references unidades(id),
  cliente_id uuid references clientes(id),
  agendamento_id uuid references agendamentos(id),
  pacote_cliente_id uuid references pacotes_cliente(id),
  forma_pagamento_id uuid references formas_pagamento(id),
  descricao text not null, valor_total numeric(10,2) not null,
  criada_em timestamptz not null default now()
);
create table parcelas_receber (
  id uuid primary key default gen_random_uuid(),
  conta_id uuid not null references contas_receber(id) on delete cascade,
  numero int not null default 1, valor numeric(10,2) not null,
  vencimento date not null, pago_em date,
  status text not null default 'pendente' check (status in ('pendente','paga','cancelada'))
);

-- FORNECEDORES, COMPRAS, ESTOQUE E CONTAS A PAGAR -----------------------
create table fornecedores (
  id uuid primary key default gen_random_uuid(),
  nome text not null, contato text, telefone text
);
create table produtos (
  id uuid primary key default gen_random_uuid(),
  nome text not null, unidade_medida text not null default 'un',
  estoque_minimo numeric(10,2) not null default 0, ativo boolean not null default true
);
create table estoque (
  produto_id uuid references produtos(id),
  unidade_id uuid references unidades(id),
  quantidade numeric(10,2) not null default 0,
  primary key (produto_id, unidade_id)
);
create table compras (
  id uuid primary key default gen_random_uuid(),
  unidade_id uuid not null references unidades(id),
  fornecedor_id uuid references fornecedores(id),
  data date not null default current_date,
  status text not null default 'pedido' check (status in ('pedido','recebida','cancelada')),
  total numeric(10,2) not null default 0
);
create table itens_compra (
  id uuid primary key default gen_random_uuid(),
  compra_id uuid not null references compras(id) on delete cascade,
  produto_id uuid not null references produtos(id),
  quantidade numeric(10,2) not null, custo_unitario numeric(10,2) not null
);
create table contas_pagar (
  id uuid primary key default gen_random_uuid(),
  unidade_id uuid not null references unidades(id),
  fornecedor_id uuid references fornecedores(id),
  compra_id uuid references compras(id),
  descricao text not null, valor numeric(10,2) not null,
  vencimento date not null, pago_em date,
  recorrente boolean not null default false,
  status text not null default 'pendente' check (status in ('pendente','paga','cancelada'))
);

-- Ao marcar a compra como recebida, o estoque da unidade é atualizado
create function atualiza_estoque() returns trigger language plpgsql as $$
begin
  if new.status = 'recebida' and old.status <> 'recebida' then
    insert into estoque (produto_id, unidade_id, quantidade)
      select i.produto_id, new.unidade_id, i.quantidade from itens_compra i where i.compra_id = new.id
    on conflict (produto_id, unidade_id) do update set quantidade = estoque.quantidade + excluded.quantidade;
  end if;
  return new;
end $$;
create trigger trg_estoque after update on compras for each row execute function atualiza_estoque();

-- FIDELIDADE E LEMBRETES (WHATSAPP) -------------------------------------
create table fidelidade_movimentos (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id),
  pontos int not null, motivo text, criado_em timestamptz not null default now()
);
create table lembretes (
  id uuid primary key default gen_random_uuid(),
  agendamento_id uuid not null references agendamentos(id) on delete cascade,
  enviar_em timestamptz not null,
  status text not null default 'pendente' check (status in ('pendente','enviado','erro'))
);

-- VIEWS PARA RELATÓRIOS -------------------------------------------------
create view v_parcelas_receber with (security_invoker = true) as
  select p.*, c.unidade_id,
    case when p.status = 'pendente' and p.vencimento < current_date then 'atrasada' else p.status end as situacao
  from parcelas_receber p join contas_receber c on c.id = p.conta_id;
create view v_faturamento_mensal with (security_invoker = true) as
  select c.unidade_id, date_trunc('month', p.pago_em)::date as mes, sum(p.valor) as total
  from parcelas_receber p join contas_receber c on c.id = p.conta_id
  where p.status = 'paga' group by 1, 2;
create view v_saldo_fidelidade with (security_invoker = true) as
  select cliente_id, sum(pontos) as pontos from fidelidade_movimentos group by 1;

-- SEGURANÇA (RLS) -------------------------------------------------------
create function is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from usuarios where id = auth.uid() and perfil = 'admin' and ativo)
$$;

do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_total on %I for all using (is_admin()) with check (is_admin())', t);
  end loop;
end $$;

-- Profissional: só a própria agenda e leitura do básico
create policy prof_usuario on usuarios for select using (id = auth.uid());
create policy prof_vinculos on usuario_unidades for select using (usuario_id = auth.uid());
create policy prof_unidades on unidades for select
  using (id in (select unidade_id from usuario_unidades where usuario_id = auth.uid()));
create policy prof_clientes on clientes for select using (auth.uid() is not null);
create policy prof_servicos on servicos for select using (auth.uid() is not null);
create policy prof_agenda on agendamentos for all
  using (profissional_id = auth.uid()) with check (profissional_id = auth.uid());

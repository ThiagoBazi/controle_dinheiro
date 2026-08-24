-- ============================================================
-- MEU DINHEIRO V9 - ATUALIZAÇÃO COMPLETA DO BANCO
-- Não apaga seus dados.
-- "Nós dois" passa a ser apenas a visão que soma as duas contas.
-- ============================================================

-- 1) Coluna usada para ordenar/sincronizar membros
ALTER TABLE public.household_members
ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

UPDATE public.household_members
SET created_at = now()
WHERE created_at IS NULL;

-- 2) Nome de cada membro
ALTER TABLE public.household_members
ADD COLUMN IF NOT EXISTS display_name text;

UPDATE public.household_members hm
SET display_name = COALESCE(
  NULLIF(u.raw_user_meta_data->>'name',''),
  split_part(u.email,'@',1)
)
FROM auth.users u
WHERE hm.user_id=u.id
  AND (hm.display_name IS NULL OR trim(hm.display_name)='');

-- 3) Garantir código de convite
UPDATE public.households
SET invite_code = upper(substr(md5(id::text || clock_timestamp()::text || random()::text),1,6))
WHERE invite_code IS NULL OR trim(invite_code)='';

CREATE UNIQUE INDEX IF NOT EXISTS households_invite_code_unique
ON public.households(invite_code);

-- 4) Salário individual de cada pessoa
CREATE TABLE IF NOT EXISTS public.member_settings (
  household_id uuid NOT NULL REFERENCES public.households(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  month text NOT NULL,
  salary numeric NOT NULL DEFAULT 0 CHECK (salary >= 0),
  PRIMARY KEY (household_id,user_id,month)
);

-- 5) Dono de cada gasto/conta
ALTER TABLE public.expenses
ADD COLUMN IF NOT EXISTS owner_scope text NOT NULL DEFAULT 'member';

ALTER TABLE public.expenses
ADD COLUMN IF NOT EXISTS owner_user_id uuid REFERENCES auth.users(id);

ALTER TABLE public.pending_items
ADD COLUMN IF NOT EXISTS owner_scope text NOT NULL DEFAULT 'member';

ALTER TABLE public.pending_items
ADD COLUMN IF NOT EXISTS owner_user_id uuid REFERENCES auth.users(id);

-- 6) Converter a lógica antiga de "Nós dois".
-- Cada lançamento antigo compartilhado fica com quem o cadastrou.
UPDATE public.expenses
SET owner_scope='member',
    owner_user_id=COALESCE(author_id,owner_user_id)
WHERE owner_scope='shared';

UPDATE public.pending_items
SET owner_scope='member',
    owner_user_id=COALESCE(author_id,owner_user_id)
WHERE owner_scope='shared';

-- Completa dono de lançamentos antigos, quando possível
UPDATE public.expenses
SET owner_user_id=author_id
WHERE owner_user_id IS NULL AND author_id IS NOT NULL;

UPDATE public.pending_items
SET owner_user_id=author_id
WHERE owner_user_id IS NULL AND author_id IS NOT NULL;

-- 7) Função de verificação de membro
CREATE OR REPLACE FUNCTION public.is_member(hid uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path=public
STABLE
AS $$
 SELECT EXISTS(
   SELECT 1 FROM public.household_members
   WHERE household_id=hid AND user_id=auth.uid()
 );
$$;

-- 8) RLS do salário
ALTER TABLE public.member_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ms_select ON public.member_settings;
DROP POLICY IF EXISTS ms_insert ON public.member_settings;
DROP POLICY IF EXISTS ms_update ON public.member_settings;
DROP POLICY IF EXISTS ms_delete ON public.member_settings;
DROP POLICY IF EXISTS authenticated_member_settings ON public.member_settings;

CREATE POLICY ms_select ON public.member_settings
FOR SELECT TO authenticated
USING (public.is_member(household_id));

CREATE POLICY ms_insert ON public.member_settings
FOR INSERT TO authenticated
WITH CHECK (public.is_member(household_id) AND user_id=auth.uid());

CREATE POLICY ms_update ON public.member_settings
FOR UPDATE TO authenticated
USING (public.is_member(household_id) AND user_id=auth.uid())
WITH CHECK (public.is_member(household_id) AND user_id=auth.uid());

CREATE POLICY ms_delete ON public.member_settings
FOR DELETE TO authenticated
USING (public.is_member(household_id) AND user_id=auth.uid());

-- 9) Funções usadas pelo app
CREATE OR REPLACE FUNCTION public.set_my_display_name_v7(
  p_household_id uuid,p_display_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
 IF NOT public.is_member(p_household_id) THEN
   RAISE EXCEPTION 'Você não pertence a este espaço';
 END IF;
 UPDATE public.household_members
 SET display_name=left(trim(p_display_name),60)
 WHERE household_id=p_household_id AND user_id=auth.uid();
END;
$$;

CREATE OR REPLACE FUNCTION public.create_household_v7(
  p_name text,p_invite_code text,p_display_name text
)
RETURNS public.households
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE h public.households;
BEGIN
 INSERT INTO public.households(name,invite_code,owner_id)
 VALUES(left(trim(p_name),80),upper(trim(p_invite_code)),auth.uid())
 RETURNING * INTO h;

 INSERT INTO public.household_members(household_id,user_id,display_name)
 VALUES(h.id,auth.uid(),left(trim(p_display_name),60))
 ON CONFLICT(household_id,user_id)
 DO UPDATE SET display_name=excluded.display_name;

 RETURN h;
END;
$$;

CREATE OR REPLACE FUNCTION public.join_household_v7(
  p_invite_code text,p_display_name text
)
RETURNS public.households
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE h public.households;
BEGIN
 SELECT * INTO h FROM public.households
 WHERE invite_code=upper(trim(p_invite_code));

 IF h.id IS NULL THEN
   RAISE EXCEPTION 'Código de convite inválido';
 END IF;

 INSERT INTO public.household_members(household_id,user_id,display_name)
 VALUES(h.id,auth.uid(),left(trim(p_display_name),60))
 ON CONFLICT(household_id,user_id)
 DO UPDATE SET display_name=excluded.display_name;

 RETURN h;
END;
$$;

REVOKE ALL ON FUNCTION public.set_my_display_name_v7(uuid,text) FROM public;
REVOKE ALL ON FUNCTION public.create_household_v7(text,text,text) FROM public;
REVOKE ALL ON FUNCTION public.join_household_v7(text,text) FROM public;

GRANT EXECUTE ON FUNCTION public.set_my_display_name_v7(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_household_v7(text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.join_household_v7(text,text) TO authenticated;

-- 10) Realtime
ALTER TABLE public.expenses REPLICA IDENTITY FULL;
ALTER TABLE public.pending_items REPLICA IDENTITY FULL;
ALTER TABLE public.member_settings REPLICA IDENTITY FULL;
ALTER TABLE public.household_members REPLICA IDENTITY FULL;

DO $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='expenses') THEN
   ALTER PUBLICATION supabase_realtime ADD TABLE public.expenses;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='pending_items') THEN
   ALTER PUBLICATION supabase_realtime ADD TABLE public.pending_items;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='member_settings') THEN
   ALTER PUBLICATION supabase_realtime ADD TABLE public.member_settings;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='household_members') THEN
   ALTER PUBLICATION supabase_realtime ADD TABLE public.household_members;
 END IF;
END $$;

NOTIFY pgrst, 'reload schema';

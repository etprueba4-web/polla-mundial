-- ============================================================
-- SCRIPT DE RESETEO COMPLETO — POLLA MUNDIALERA PRO v2
-- Actualizado para: API OpenLigaDB, comodín, organigrama,
-- sincronización automática de puntos en vivo
-- ============================================================

-- ============================================================
-- 0. PERMISOS DE ESQUEMA
-- ============================================================
ALTER SCHEMA public OWNER TO postgres;

GRANT USAGE  ON SCHEMA public TO postgres;
GRANT CREATE ON SCHEMA public TO postgres;
GRANT USAGE  ON SCHEMA public TO anon;
GRANT USAGE  ON SCHEMA public TO authenticated;
GRANT USAGE  ON SCHEMA public TO service_role;

-- ============================================================
-- 1. LIMPIAR OBJETOS EXISTENTES
-- ============================================================
DROP FUNCTION IF EXISTS public.calcular_puntos_pronostico()  CASCADE;
DROP FUNCTION IF EXISTS public.calcular_puntos_en_vivo()     CASCADE;
DROP FUNCTION IF EXISTS public.add_creator_to_group()        CASCADE;
DROP FUNCTION IF EXISTS public.is_member_of_group(UUID)      CASCADE;

DROP TABLE IF EXISTS public.chat_messages    CASCADE;
DROP TABLE IF EXISTS public.fund_transactions CASCADE;
DROP TABLE IF EXISTS public.predictions      CASCADE;
DROP TABLE IF EXISTS public.group_members    CASCADE;
DROP TABLE IF EXISTS public.groups           CASCADE;
DROP TABLE IF EXISTS public.matches          CASCADE;
DROP TABLE IF EXISTS public.profiles         CASCADE;

DROP VIEW IF EXISTS public.v_ranking_grupo   CASCADE;

-- ============================================================
-- 2. CREAR TABLAS
-- ============================================================

CREATE TABLE public.profiles (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username   TEXT UNIQUE NOT NULL,
  avatar_url TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.groups (
  id                UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name              TEXT NOT NULL,
  created_by        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  config            JSONB NOT NULL DEFAULT '{
    "tipo_pronostico":        "marcador",
    "puntos_ganador":         3,
    "puntos_empate":          1,
    "puntos_marcador_exacto": 5,
    "minutos_limite_antes":   30,
    "minutos_poll":           15,
    "porcentajes_premios":    {"1": 50, "2": 30, "3": 15, "4": 5}
  }'::jsonb,
  fondo_comun_total NUMERIC DEFAULT 0,
  created_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.group_members (
  id        UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  group_id  UUID NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  user_id   UUID NOT NULL REFERENCES auth.users(id)   ON DELETE CASCADE,
  role      TEXT DEFAULT 'member',
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(group_id, user_id)
);

-- id TEXT para almacenar el matchID numérico de OpenLigaDB directamente
CREATE TABLE public.matches (
  id             TEXT PRIMARY KEY,
  home_team      TEXT NOT NULL,
  away_team      TEXT NOT NULL,
  match_datetime TIMESTAMPTZ NOT NULL,
  status         TEXT DEFAULT 'scheduled', -- scheduled | live | finished
  result         JSONB,                    -- {"home": 2, "away": 1}
  group_name     TEXT,                     -- fase/grupo del partido
  created_at     TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.predictions (
  id             UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  match_id       TEXT NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  user_id        UUID NOT NULL REFERENCES auth.users(id)     ON DELETE CASCADE,
  group_id       UUID NOT NULL REFERENCES public.groups(id)  ON DELETE CASCADE,
  predicted_home INT,
  predicted_away INT,
  points_earned  INT,
  joker_used     BOOLEAN DEFAULT FALSE, -- comodín: solo 1 por usuario por mundial
  created_at     TIMESTAMPTZ DEFAULT NOW(),
  updated_at     TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(match_id, user_id, group_id)
);

CREATE TABLE public.fund_transactions (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  group_id    UUID NOT NULL REFERENCES public.groups(id)  ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES auth.users(id)     ON DELETE CASCADE,
  amount      NUMERIC NOT NULL,
  description TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.chat_messages (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  group_id   UUID NOT NULL REFERENCES public.groups(id)  ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES auth.users(id)     ON DELETE CASCADE,
  message    TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 3. GRANT DML A ROLES DE SUPABASE
--    Sin esto los roles no pueden ni leer las tablas,
--    independientemente de las políticas RLS.
-- ============================================================

-- authenticated: puede hacer todo (RLS filtra qué filas)
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles          TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.groups            TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_members     TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.matches           TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.predictions       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.fund_transactions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.chat_messages     TO authenticated;

-- anon: solo lectura en tablas que lo necesiten (matches es pública)
GRANT SELECT ON public.matches  TO anon;
GRANT SELECT ON public.profiles TO anon;

-- service_role: acceso total sin RLS (para triggers y funciones internas)
GRANT ALL ON public.profiles          TO service_role;
GRANT ALL ON public.groups            TO service_role;
GRANT ALL ON public.group_members     TO service_role;
GRANT ALL ON public.matches           TO service_role;
GRANT ALL ON public.predictions       TO service_role;
GRANT ALL ON public.fund_transactions TO service_role;
GRANT ALL ON public.chat_messages     TO service_role;

-- Secuencias (necesario para INSERT con columnas serial/uuid en algunos contextos)
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO service_role;

-- ============================================================
-- 4. FUNCIONES AUXILIARES
-- ============================================================

-- Verificar membresía (usada en políticas RLS)
CREATE OR REPLACE FUNCTION public.is_member_of_group(group_id_param UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.group_members
    WHERE group_id = group_id_param
      AND user_id  = auth.uid()
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_member_of_group(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_member_of_group(UUID) TO anon;

-- Agregar al creador como admin cuando se crea un grupo
CREATE OR REPLACE FUNCTION public.add_creator_to_group()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.group_members (group_id, user_id, role)
  VALUES (NEW.id, NEW.created_by, 'admin')
  ON CONFLICT (group_id, user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- Calcular puntos cuando resultado cambia (en vivo o al finalizar)
-- Respeta el comodín duplicando puntos si joker_used = TRUE
CREATE OR REPLACE FUNCTION public.calcular_puntos_pronostico()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pred_record    RECORD;
  puntos         INT;
  signo_real     INT;
  signo_pred     INT;
  acierto_exacto BOOLEAN;
BEGIN
  -- Actuar cuando el resultado cambia (en vivo o al finalizar)
  IF NEW.result IS NOT NULL AND (OLD.result IS DISTINCT FROM NEW.result) THEN

    signo_real := CASE
      WHEN (NEW.result->>'home')::int > (NEW.result->>'away')::int THEN  1
      WHEN (NEW.result->>'home')::int < (NEW.result->>'away')::int THEN -1
      ELSE 0
    END;

    FOR pred_record IN
      SELECT p.*, g.config AS grupo_config
      FROM   public.predictions p
      JOIN   public.groups      g ON g.id = p.group_id
      WHERE  p.match_id = NEW.id
    LOOP
      puntos := 0;

      acierto_exacto := (
        pred_record.predicted_home = (NEW.result->>'home')::int AND
        pred_record.predicted_away = (NEW.result->>'away')::int
      );

      IF acierto_exacto THEN
        puntos := (pred_record.grupo_config->>'puntos_marcador_exacto')::int;
      ELSE
        signo_pred := CASE
          WHEN pred_record.predicted_home > pred_record.predicted_away THEN  1
          WHEN pred_record.predicted_home < pred_record.predicted_away THEN -1
          ELSE 0
        END;

        IF signo_pred = signo_real THEN
          IF signo_real = 0 THEN
            puntos := (pred_record.grupo_config->>'puntos_empate')::int;
          ELSE
            puntos := (pred_record.grupo_config->>'puntos_ganador')::int;
          END IF;
        END IF;
      END IF;

      -- Comodín: duplicar puntos
      IF pred_record.joker_used THEN
        puntos := puntos * 2;
      END IF;

      UPDATE public.predictions
      SET    points_earned = puntos,
             updated_at    = NOW()
      WHERE  id = pred_record.id;
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

-- ============================================================
-- 5. TRIGGERS
-- ============================================================

DROP TRIGGER IF EXISTS trigger_add_creator      ON public.groups;
CREATE TRIGGER trigger_add_creator
  AFTER INSERT ON public.groups
  FOR EACH ROW
  EXECUTE FUNCTION public.add_creator_to_group();

DROP TRIGGER IF EXISTS trigger_calcular_puntos  ON public.matches;
CREATE TRIGGER trigger_calcular_puntos
  AFTER UPDATE ON public.matches
  FOR EACH ROW
  WHEN (NEW.result IS DISTINCT FROM OLD.result)
  EXECUTE FUNCTION public.calcular_puntos_pronostico();

-- ============================================================
-- 6. ROW LEVEL SECURITY
-- ============================================================
ALTER TABLE public.profiles          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.groups            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_members     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.matches           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.predictions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fund_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages     ENABLE ROW LEVEL SECURITY;

-- ── profiles ──────────────────────────────────────────────
CREATE POLICY "profiles_select_all"  ON public.profiles
  FOR SELECT USING (true);

CREATE POLICY "profiles_insert_self" ON public.profiles
  FOR INSERT WITH CHECK (auth.uid() = id);

CREATE POLICY "profiles_update_self" ON public.profiles
  FOR UPDATE USING (auth.uid() = id);

-- ── groups ────────────────────────────────────────────────
-- Al crear un grupo el trigger aún no añadió al miembro,
-- así que SELECT durante el INSERT necesita permiso extra:
-- usamos la política de insert sin restricción de membresía.
CREATE POLICY "groups_insert_creator" ON public.groups
  FOR INSERT WITH CHECK (auth.uid() = created_by);

CREATE POLICY "groups_select_members" ON public.groups
  FOR SELECT USING (
    created_by = auth.uid()                    -- el creador siempre ve su grupo
    OR public.is_member_of_group(id)           -- o es miembro
  );

CREATE POLICY "groups_update_creator" ON public.groups
  FOR UPDATE USING (auth.uid() = created_by);

-- ── group_members ─────────────────────────────────────────
CREATE POLICY "members_insert_self" ON public.group_members
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "members_select_group" ON public.group_members
  FOR SELECT USING (public.is_member_of_group(group_id));

CREATE POLICY "members_delete_creator" ON public.group_members
  FOR DELETE USING (
    EXISTS (
      SELECT 1 FROM public.groups
      WHERE id = group_id AND created_by = auth.uid()
    )
  );

-- ── matches ───────────────────────────────────────────────
CREATE POLICY "matches_select_all" ON public.matches
  FOR SELECT USING (true);

CREATE POLICY "matches_insert_auth" ON public.matches
  FOR INSERT WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "matches_update_auth" ON public.matches
  FOR UPDATE USING (auth.role() = 'authenticated');

-- ── predictions ───────────────────────────────────────────
CREATE POLICY "predictions_select_group" ON public.predictions
  FOR SELECT USING (public.is_member_of_group(group_id));

CREATE POLICY "predictions_insert_self" ON public.predictions
  FOR INSERT WITH CHECK (
    auth.uid() = user_id
    AND public.is_member_of_group(group_id)
  );

CREATE POLICY "predictions_update_self" ON public.predictions
  FOR UPDATE USING (auth.uid() = user_id);

-- ── fund_transactions ─────────────────────────────────────
CREATE POLICY "fund_select_members" ON public.fund_transactions
  FOR SELECT USING (public.is_member_of_group(group_id));

CREATE POLICY "fund_insert_creator" ON public.fund_transactions
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.groups
      WHERE id = group_id AND created_by = auth.uid()
    )
  );

-- ── chat_messages ─────────────────────────────────────────
CREATE POLICY "chat_select_members" ON public.chat_messages
  FOR SELECT USING (public.is_member_of_group(group_id));

CREATE POLICY "chat_insert_members" ON public.chat_messages
  FOR INSERT WITH CHECK (
    auth.uid() = user_id
    AND public.is_member_of_group(group_id)
  );

-- ============================================================
-- 7. REALTIME
-- ============================================================
ALTER TABLE public.chat_messages REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname    = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename  = 'chat_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;
  END IF;
END $$;

-- ============================================================
-- 8. ÍNDICES
-- ============================================================
CREATE INDEX idx_predictions_match_group ON public.predictions(match_id, group_id);
CREATE INDEX idx_predictions_user_group  ON public.predictions(user_id,  group_id);
CREATE INDEX idx_predictions_joker       ON public.predictions(user_id,  group_id) WHERE joker_used = TRUE;
CREATE INDEX idx_matches_datetime        ON public.matches(match_datetime);
CREATE INDEX idx_matches_status          ON public.matches(status);
CREATE INDEX idx_group_members_user      ON public.group_members(user_id);
CREATE INDEX idx_group_members_group     ON public.group_members(group_id);
CREATE INDEX idx_chat_group_date         ON public.chat_messages(group_id, created_at DESC);
CREATE INDEX idx_fund_group              ON public.fund_transactions(group_id);

-- ============================================================
-- 9. VISTA: ranking por grupo
-- ============================================================
CREATE OR REPLACE VIEW public.v_ranking_grupo AS
SELECT
  gm.group_id,
  gm.user_id,
  pr.username,
  COALESCE(SUM(p.points_earned), 0)              AS total_puntos,
  COUNT(p.id)                                    AS partidos_pronosticados,
  BOOL_OR(p.joker_used)                          AS comodin_usado,
  RANK() OVER (
    PARTITION BY gm.group_id
    ORDER BY COALESCE(SUM(p.points_earned), 0) DESC
  )                                              AS posicion
FROM      public.group_members gm
LEFT JOIN public.predictions   p  ON p.user_id  = gm.user_id AND p.group_id = gm.group_id
LEFT JOIN public.profiles      pr ON pr.id = gm.user_id
GROUP BY  gm.group_id, gm.user_id, pr.username;

GRANT SELECT ON public.v_ranking_grupo TO authenticated;
GRANT SELECT ON public.v_ranking_grupo TO anon;

-- ============================================================
-- 10. VERIFICACIÓN FINAL
-- ============================================================
SELECT 'OK — Polla Mundialera Pro v2 lista' AS resultado;

SELECT tabla, registros FROM (
  SELECT 'profiles'          AS tabla, COUNT(*)::text AS registros FROM public.profiles
  UNION ALL
  SELECT 'groups',                     COUNT(*)::text FROM public.groups
  UNION ALL
  SELECT 'group_members',              COUNT(*)::text FROM public.group_members
  UNION ALL
  SELECT 'matches',                    COUNT(*)::text FROM public.matches
  UNION ALL
  SELECT 'predictions',                COUNT(*)::text FROM public.predictions
  UNION ALL
  SELECT 'fund_transactions',          COUNT(*)::text FROM public.fund_transactions
  UNION ALL
  SELECT 'chat_messages',              COUNT(*)::text FROM public.chat_messages
) t;

-- Permite a cualquier usuario autenticado leer la información de todos los grupos
CREATE POLICY "Auth users can view all groups"
ON groups FOR SELECT
TO authenticated
USING (true);

-- Permitir a cualquier miembro del grupo actualizar points_earned de las predicciones de ese grupo
CREATE POLICY "Group members can update points"
ON predictions
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM group_members
    WHERE group_members.group_id = predictions.group_id
      AND group_members.user_id = auth.uid()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM group_members
    WHERE group_members.group_id = predictions.group_id
      AND group_members.user_id = auth.uid()
  )
);


document.getElementById("doLogin").onclick = async () => {
  const { data, error } = await supabase.auth.signInWithPassword({
    email: document.getElementById("loginEmail").value,
    password: document.getElementById("loginPassword").value
  });
  if (error) {
    showModal("Error al ingresar", error.message, true);
    return;
  }
  const user = data?.user;
  if (user) {
    await supabase.from('login_origins').insert({
      user_id: user.id,
      origin_url: window.location.href
    });
  }
  loadUser();
};

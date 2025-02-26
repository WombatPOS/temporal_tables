-- version 0.6.0

CREATE OR REPLACE FUNCTION versioning()
RETURNS TRIGGER AS $$
DECLARE
  sys_period text;
  history_table text;
  manipulate jsonb;
  ignore_unchanged_values bool;
  commonColumns text[];
  time_stamp_to_use timestamptz;
  range_lower timestamptz;
  existing_range tstzrange;
  newVersion record;
  oldVersion record;
  user_defined_system_time text;
BEGIN
  -- set custom system time if exists
  BEGIN
    SELECT current_setting('user_defined.system_time') INTO user_defined_system_time;
    IF NOT FOUND OR (user_defined_system_time <> '') IS NOT TRUE THEN
      time_stamp_to_use := CURRENT_TIMESTAMP;
    ELSE
      SELECT TO_TIMESTAMP(
          user_defined_system_time,
          'YYYY-MM-DD HH24:MI:SS'
      ) INTO time_stamp_to_use;
    END IF;
    EXCEPTION WHEN OTHERS THEN
      time_stamp_to_use := CURRENT_TIMESTAMP;
  END;

  -- version 0.4.0

  sys_period := TG_ARGV[0];
  history_table := TG_ARGV[1];
  ignore_unchanged_values := TG_ARGV[3];

  IF ignore_unchanged_values AND TG_OP = 'UPDATE' THEN
    IF NEW IS NOT DISTINCT FROM OLD THEN
      RETURN OLD;
    END IF;
  END IF;

  IF TG_OP = 'UPDATE' OR TG_OP = 'DELETE' THEN
    -- Ignore rows already modified in the current transaction
    IF OLD.xmin::text = (txid_current() % (2^32)::bigint)::text THEN
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      RETURN NEW;
    END IF;

    EXECUTE format('SELECT $1.%I', sys_period) USING OLD INTO existing_range;

    IF TG_ARGV[2] = 'true' THEN
      -- mitigate update conflicts
      range_lower := lower(existing_range);
      IF range_lower >= time_stamp_to_use THEN
        time_stamp_to_use := range_lower + interval '1 microseconds';
      END IF;
    END IF;

    WITH history AS
      (SELECT attname
      FROM   pg_attribute
      WHERE  attrelid = history_table::regclass
      AND    attnum > 0
      AND    NOT attisdropped),
      main AS
      (SELECT attname
      FROM   pg_attribute
      WHERE  attrelid = TG_RELID
      AND    attnum > 0
      AND    NOT attisdropped)
    SELECT array_agg(quote_ident(history.attname)) INTO commonColumns
      FROM history
      INNER JOIN main
      ON history.attname = main.attname
      AND history.attname != sys_period;
    -- skip version if it would be identical to the previous version
    IF ignore_unchanged_values AND TG_OP = 'UPDATE' AND array_length(commonColumns, 1) > 0 THEN      EXECUTE 'SELECT ROW($1.' || array_to_string(commonColumns , ', $1.') || ')'
        USING NEW
        INTO newVersion;
      EXECUTE 'SELECT ROW($1.' || array_to_string(commonColumns , ', $1.') || ')'
        USING OLD
        INTO oldVersion;
      IF newVersion IS NOT DISTINCT FROM oldVersion THEN
        RETURN NEW;
      END IF;
    END IF;
    EXECUTE ('INSERT INTO ' ||
      history_table ||
      '(' ||
      array_to_string(commonColumns , ',') ||
      ',' ||
      quote_ident(sys_period) ||
      ') VALUES ($1.' ||
      array_to_string(commonColumns, ',$1.') ||
      ',tstzrange($2, $3, ''[)''))')
       USING OLD, range_lower, time_stamp_to_use;
  END IF;

  IF TG_OP = 'UPDATE' OR TG_OP = 'INSERT' THEN
    manipulate := jsonb_set('{}'::jsonb, ('{' || sys_period || '}')::text[], to_jsonb(tstzrange(time_stamp_to_use, null, '[)')));

    RETURN jsonb_populate_record(NEW, manipulate);
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

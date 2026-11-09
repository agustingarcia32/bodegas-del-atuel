# Reparto del trabajo y de los commits

| Persona | Sube | Presenta |
|---|---|---|
| 1 | migrations/001_esquema.sql, 002_constraints.sql; docs/ (DER, normalizacion, diccionario, decisiones); docs/trazabilidad.md; docs/informe_final.md y defensa_preguntas.md (con aportes de todos) | Objetivo, modelo, constraints |
| 2 | migrations/003_funciones.sql, 004_procedimientos.sql, 005_triggers.sql, 006_vistas.sql, 009_vista_ficha_vino.sql; tests/; docs/concurrencia.md | Reglas, funciones, concurrencia |
| 3 | seed/; docs/etapa3_carga.md; migrations/008_indices.sql; rendimiento/; docs/etapa4_indices.md; consultas/; docs/etapa5_consultas.md | Carga, indices, consultas |
| 4 | migrations/007_roles.sql; api/; front/; docs/etapa8_nube.md; docker-compose.yml; .env.example; .gitignore; README.md | Roles, API, nube |

Cada integrante hace sus commits con su propio usuario (git config user.name / user.email con el mail de su GitHub), en varios commits chicos.
El primero en subir sube tambien .gitignore (evita subir .env, .venv, datos generados y dumps).

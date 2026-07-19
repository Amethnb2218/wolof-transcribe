# Wolof Transcriber - Notes Deploiement AWS Lambda

## Etat actuel (19 juillet 2026)

### Ce qui est fait :
- Image Docker `wolof-asr:latest` construite (795 Mo)
- Image pushee sur ECR : `335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr:latest`
- Compte AWS : 335596040822 (user: sonnena)
- Region : us-east-1

### Ce qui reste :
1. Ajouter permission `IAMFullAccess` au user sonnena
2. Creer le role Lambda (wolof-asr-lambda-role)
3. Creer la fonction Lambda
4. Activer la Function URL (endpoint public)
5. Mettre l'URL dans le .env de l'app

---

## Architecture

```
App React Native --> Function URL (HTTPS) --> Lambda (wolof-asr)
                                                |
                                                v
                                    Container Docker (python:3.11-slim)
                                    - faster-whisper (CPU, int8)
                                    - Modele telecharge depuis HuggingFace au cold start
                                    - Cache dans /tmp (10 Go ephemeral storage)
```

## Budget AWS estime

### Lambda :
- Memory : 3008 Mo (necessaire pour le modele en memoire)
- Timeout : 300s max (transcription ~10-30s par audio)
- Ephemeral storage : 10 Go (pour le modele ~3Go)
- Cold start : ~60-90s (telechargement modele HuggingFace)

### Cout estime :
- Free tier Lambda : 1M requetes/mois + 400,000 Go-secondes GRATUITES
- Au dela : $0.0000166667 par Go-seconde
- Exemple : 100 transcriptions/jour x 30s x 3Go = 270,000 Go-sec/mois = GRATUIT (sous le free tier)
- Meme 500 transcriptions/jour reste dans le free tier la premiere annee

### ECR :
- Stockage : 500 Mo gratuit/mois (free tier)
- Notre image : ~191 Mo compresse = GRATUIT

### Transfert donnees :
- 100 Go/mois sortant = gratuit la premiere annee
- Audio WAV de 30s ~ 1 Mo = 1000 requetes/jour = 30 Go/mois = GRATUIT

### TOTAL ESTIME : 0$ pour un usage normal (< 500 transcriptions/jour)

---

## Commandes de deploiement (a executer quand IAM est configure)

```bash
# 1. Creer le role
aws iam create-role \
  --role-name wolof-asr-lambda-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# 2. Attacher la policy de base
aws iam attach-role-policy \
  --role-name wolof-asr-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# 3. Attendre 10 secondes (propagation IAM)
sleep 10

# 4. Creer la Lambda
aws lambda create-function \
  --function-name wolof-asr \
  --package-type Image \
  --code ImageUri=335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr:latest \
  --role arn:aws:iam::335596040822:role/wolof-asr-lambda-role \
  --timeout 300 \
  --memory-size 3008 \
  --ephemeral-storage '{"Size": 10240}' \
  --region us-east-1

# 5. Creer la Function URL (endpoint public)
aws lambda create-function-url-config \
  --function-name wolof-asr \
  --auth-type NONE \
  --cors '{"AllowOrigins":["*"],"AllowMethods":["POST","OPTIONS"],"AllowHeaders":["*"]}'

# 6. Autoriser l'acces public
aws lambda add-permission \
  --function-name wolof-asr \
  --statement-id FunctionURLAllowPublicAccess \
  --action lambda:InvokeFunctionUrl \
  --principal "*" \
  --function-url-auth-type NONE
```

## Fichiers du projet

- `deploy-lambda/Dockerfile` : Image Docker (python:3.11-slim + faster-whisper)
- `deploy-lambda/handler.py` : Handler Lambda (transcription audio)
- `deploy-lambda/requirements.txt` : Dependances Python
- Modele HuggingFace : `momosl/whisper-wolof-v1` (telecharge au cold start)

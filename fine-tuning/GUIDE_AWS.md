# Guide AWS — Fine-tuning Whisper (p4d.24xlarge)

## Etape 1 : Lancer l'instance EC2

1. Va dans **EC2** > **Launch Instance**
2. Nom : `whisper-wolof-training`
3. AMI : cherche **"Deep Learning OSS Nvidia Driver AMI GPU PyTorch 2"** (Ubuntu)
   - Ou tape "Deep Learning AMI" dans la barre de recherche
   - Choisis celle avec PyTorch pre-installe
4. Instance type : **p4d.24xlarge**
5. Key pair : Cree une nouvelle cle (ex: `whisper-key`) > Download .pem
6. Storage : mets **500 GB** (gp3)
7. Security group : autorise SSH (port 22) depuis ton IP
8. **Launch instance**

## Etape 2 : Se connecter

Attends 2-3 min que l'instance demarre, puis :

```bash
# Windows (PowerShell ou Git Bash)
ssh -i whisper-key.pem ubuntu@<IP-PUBLIQUE>
```

L'IP publique se trouve dans EC2 > Instances > ton instance > Public IPv4.

Si erreur "permission denied" sur Windows :
```bash
icacls whisper-key.pem /inheritance:r /grant:r "%USERNAME%:R"
```

## Etape 3 : Installer les dependances

```bash
# Activer l'environnement PyTorch
source activate pytorch
# ou si ca ne marche pas :
conda activate pytorch

# Installer les packages
pip install transformers==4.46.0 datasets==3.1.0 accelerate==1.1.0
pip install evaluate jiwer tensorboard soundfile librosa
pip install huggingface_hub pydub scipy
```

## Etape 4 : Configurer accelerate (multi-GPU)

```bash
accelerate config
```

Reponds :
- Machine type : **multi-GPU**
- Num GPUs : **8**
- Mixed precision : **bf16**
- Tout le reste : valeurs par defaut (Enter)

## Etape 5 : Uploader le script

Depuis ton PC (autre terminal) :
```bash
scp -i whisper-key.pem C:\Users\HP\Desktop\wolof-transcriber\fine-tuning\train_aws.py ubuntu@<IP>:~/train_aws.py
```

## Etape 6 : Lancer l'entrainement (dans tmux)

```bash
# Lancer tmux (pour que ca continue meme si tu te deconnectes)
tmux new -s training

# Lancer l'entrainement
accelerate launch train_aws.py
```

Pour se detacher de tmux : **Ctrl+B puis D**
Pour revenir : `tmux attach -t training`

## Etape 7 : Attendre ~2h

L'entrainement tourne. Tu peux fermer ton PC, la connexion, tout.
Pour verifier : reconnecte-toi en SSH puis `tmux attach -t training`

## Etape 8 : Recuperer le modele

Quand c'est fini, depuis ton PC :
```bash
scp -r -i whisper-key.pem ubuntu@<IP>:~/whisper-wolof-mega C:\Users\HP\Desktop\wolof-transcriber\backend\models\whisper-wolof-mega
```

## Etape 9 : ARRETER L'INSTANCE !!

TRES IMPORTANT — sinon tu paies 32$/h pour rien :
1. EC2 > Instances > Selectionne ton instance
2. Instance state > **Terminate instance**

## Cout estime

- ~30min setup + download dataset
- ~2h entrainement
- Total : ~2.5h x 32$/h = **~80$** sur tes 200$ de credits

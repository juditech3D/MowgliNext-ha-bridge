# mowglinext-ha-bridge

[English](README.md) · **Français**

Publie l'état en direct d'une tondeuse **MowgliNext** sur MQTT, pour que **Home
Assistant** puisse le lire — sans rien modifier sur le robot.

Installez, répondez à cinq questions, et un appareil `Mowgli` apparaît dans Home
Assistant avec la batterie, la lame, le GPS, le chargeur et l'arrêt d'urgence.

---

## Pourquoi cet outil existe

MowgliNext propose une page *MQTT / Home Assistant* dans son interface web, avec
les champs pour l'hôte du broker, le port et les identifiants. Sur les images
publiées, cette page ne peut pas fonctionner, pour deux raisons indépendantes.

**1. Le nœud ROS2 est une coquille vide dans toutes les images livrées.**
`mqtt_bridge_node.cpp` choisit son client MQTT à la compilation :

```cpp
  mqtt_client_ = std::make_unique<MosquittoMqttClient>(std::move(cfg), get_logger());
#else
  mqtt_client_ = std::make_unique<StubMqttClient>(get_logger());
  RCLCPP_WARN(get_logger(),
              "libmosquitto not available — using StubMqttClient. "
              "MQTT messages will be logged at DEBUG level only.");
#endif
```

Or l'image `ros2` ne contient pas libmosquitto :

```console
$ docker exec mowgli-ros2 ldconfig -p | grep -ci mosquitto
0
```

C'est donc la branche `#else` qui est livrée. Le nœud existe, démarre, et ne
publie rien.

**2. De toute façon, il n'est jamais lancé.**
Dans `full_system.launch.py`, il est conditionné par
`condition=IfCondition(enable_mqtt)`, et `enable_mqtt` vaut `"false"` par
défaut. La commande du compose passe `enable_foxglove:=…` mais aucun
`enable_mqtt:=…`, et `ENABLE_MQTT` dans `docker/.env` ne démarre que le
conteneur **broker** eclipse-mosquitto — pas le pont.

Activer l'interrupteur de l'interface écrit `mqtt_enabled: true` dans
`mowgli_robot.yaml`, que rien ne lit. Vérifié sur MowgliNext v1.3.0.

Ce pont prend une autre route : il se connecte à l'API WebSocket du robot —
celle-là même qu'utilise son interface web — et republie chaque message en JSON
retenu sur votre broker. Le robot n'est jamais que lu.

---

## Ce que vous obtenez

| Topic MQTT | Source | Contenu |
|---|---|---|
| `mowgli/status` | ROS `status` | régime de lame, courant et état de l'ESC, température moteur, firmware, pluie |
| `mowgli/power` | ROS `power` | tension batterie, courant de charge, état du chargeur |
| `mowgli/emergency` | ROS `emergency` | arrêt d'urgence actif et verrouillé, motif, alerte de levage |
| `mowgli/high_level_status` | ROS `highLevelStatus` | nom d'état, batterie %, couverture, qualité GPS |
| `mowgli/gps` | ROS `gnssStatus` | type de fix, corrections RTK, précision |
| `mowgli/command` | vous | démarrer / pause / base (abonnement) |
| `mowgli/command/result` | le pont | résultat de la dernière commande |
| `mowgli/available` | le pont | `online` / `offline` (dernière volonté MQTT) |

Tous les topics d'état sont publiés **retenus**, pour que Home Assistant ait des
valeurs immédiatement au redémarrage au lieu d'attendre le message suivant.

---

## Prérequis

- Python 3.9+ — **bibliothèque standard uniquement**, rien à installer avec pip
- Un broker MQTT. Pour Home Assistant, c'est le module Mosquitto, et le compte
  est un utilisateur Home Assistant ordinaire.
- Une machine qui joint à la fois le robot et le broker. Le Raspberry Pi du
  robot est l'endroit naturel : toujours allumé, et le robot est sur
  `127.0.0.1`.

## Installation

En une ligne, sur le Pi du robot :

```bash
curl -fsSL https://raw.githubusercontent.com/juditech3D/MowgliNext-ha-bridge/main/install.sh | sudo bash
```

Ou clonez d'abord, si vous préférez lire le script avant de le passer à root —
ce qui est la bonne habitude :

```bash
git clone https://github.com/juditech3D/MowgliNext-ha-bridge.git
cd MowgliNext-ha-bridge
sudo ./install.sh
```

L'installeur demande l'adresse du robot, celle du broker et son port, puis le
**nom d'utilisateur et le mot de passe MQTT**. Le mot de passe est saisi masqué
et écrit uniquement dans `/etc/mowglinext-ha-bridge.conf`, `chmod 0600`,
propriété de root. Il n'est jamais affiché et ne quitte jamais la machine.

Il cherche votre broker au lieu d'attendre que vous récitiez une adresse IP : il
résout le nom que Home Assistant annonce en mDNS, et à défaut balaie le `/24`
local à la recherche d'un hôte répondant à la fois sur 8123 et 1883. Ce qu'il
trouve est proposé par défaut — Entrée pour accepter, ou tapez la vôtre.

```
Recherche d'un broker MQTT Home Assistant...
✓ Home Assistant avec MQTT trouvé à 192.168.1.239
  Adresse du broker [192.168.1.239] :
```

L'installeur demande d'abord votre langue, français ou anglais. `--lang fr` ou
`--lang en` court-circuite la question.

<details>
<summary>Pourquoi la commande en une ligne demande une ruse — deux, en fait</summary>

Passer un script à bash par un tube casse les questions interactives de deux
façons, et ne corriger que la première produit une installation subtilement
cassée plutôt qu'un échec visible.

**D'abord**, bash lit le script sur l'entrée standard, donc un `read`
consommerait le script lui-même. L'installeur détecte qu'il n'a pas de fichier
à lui, se télécharge dans un fichier temporaire et se relance depuis là.

**Ensuite — et c'est celle qui mord** — après la ré-exécution, l'entrée standard
*est toujours le tube*, et le tube contient encore la fin du script que bash
n'avait pas consommée. `read` rend ces octets résiduels comme si vous les aviez
tapés. Résultat : un installeur qui ne demande rien et écrit une configuration
remplie de son propre code source :

```
ROBOT_PORT=# Second pass of a one-line install: tidy the copy we downloaded…
MQTT_HOST=# Written as an `if` on purpose: under `set -e`, a bare `[[ … ]]`…
TOPIC_PREFIX=fi
```

La ré-exécution pointe donc aussi l'entrée standard sur `/dev/tty`. Sans
terminal disponible, elle se rabat sur `/dev/null` et les réponses doivent
venir de l'environnement.

Ceinture et bretelles : chaque réponse est désormais validée avant toute
écriture. Un port qui n'est pas un nombre, une adresse qui n'est pas une
adresse, et l'installeur s'arrête avec un message clair au lieu de refaire
surface une heure plus tard en trace d'exception dans le journal.

</details>

### Installation sans question

Toute réponse déjà présente dans l'environnement est reprise telle quelle :

```bash
sudo MQTT_HOST=192.168.1.10 MQTT_USERNAME=mowgli MQTT_PASSWORD='…' ./install.sh
```

Pratique pour provisionner plusieurs robots. Attention : un mot de passe écrit
en ligne de commande atterrit dans l'historique du shell — pour une
installation unique, laissez le script le demander.

### Créer le compte MQTT dans Home Assistant

Le module Mosquitto authentifie contre les utilisateurs Home Assistant.
**Paramètres → Personnes → Utilisateurs → Ajouter**, créez un utilisateur (par
exemple `mowgli`), et donnez ces identifiants à l'installeur. Une ligne
`not authorised` dans le journal signifie presque toujours que cette étape a
été sautée.

## Sécurité

### Ce que `curl … | sudo bash` signifie vraiment

Cela exécute, en root, ce que cette URL renvoie *à cet instant*, sans que vous
l'ayez vu. C'est un risque réel, et il vaut mieux l'énoncer que le cacher
derrière une commande commode.

Concrètement, pour ce projet :

- **Tout repose sur le dépôt GitHub.** Qui le contrôle contrôle ce qui tourne
  en root sur votre Pi. Aujourd'hui, son propriétaire — et quiconque
  compromettrait ce compte.
- **Il n'y a ni signature ni somme de contrôle.** Une somme publiée dans le
  même dépôt n'attraperait qu'un téléchargement tronqué, pas un dépôt altéré :
  elle n'apporterait presque rien tout en suggérant une garantie inexistante.
- **L'installeur télécharge deux fois** — lui-même, puis le pont — laissant une
  fenêtre théorique où les deux pourraient différer.

Deux façons de lever le doute :

```bash
# Le lire avant de le passer à root
curl -fsSL https://raw.githubusercontent.com/juditech3D/MowgliNext-ha-bridge/main/install.sh -o install.sh
less install.sh && sudo bash install.sh
```

```bash
# Ou épingler un commit précis : immuable, relisible, reproductible
curl -fsSL https://raw.githubusercontent.com/juditech3D/MowgliNext-ha-bridge/<sha-du-commit>/install.sh | sudo bash
```

L'ensemble fait environ 400 lignes de Python et de shell, délibérément gardées
lisibles pour qu'une relecture soit réaliste plutôt que théorique.

### Ce que le code fait réellement

- **Aucune exécution dynamique.** Pas d'`eval`, pas d'`exec`, pas de
  `subprocess`, pas de `pickle`, aucun appel au shell. Les données MQTT et
  WebSocket entrantes passent par `json.loads` et ne sont jamais interprétées.
- **Deux connexions sortantes**, toutes deux via `socket.create_connection` :
  votre robot, et votre broker. Rien d'autre. Aucune télémétrie.
- **Trois fichiers écrits**, tous nommés dans le source : le programme, la
  configuration, l'unité systemd. La désinstallation retire exactement ceux-là.
- **Lecture seule vers le robot.** Le pont s'abonne à l'API WebSocket ; aucun
  chemin de code ne lui envoie de commande.

### Le service ne tourne pas en root

L'installeur a besoin de root — il écrit dans `/usr/local/bin` et
`/etc/systemd/system`. Le **service**, non, et ne l'obtient donc pas :

```ini
DynamicUser=yes
LoadCredential=conf:/etc/mowglinext-ha-bridge.conf
ExecStart=/usr/local/bin/mowglinext-ha-bridge %d/conf
```

`DynamicUser` lui donne un compte jetable et non privilégié pour la durée du
service — rien à créer, rien qui subsiste. Le fichier de configuration reste
propriété de root en `0600` ; systemd le lit pendant qu'il est encore
privilégié et le transmet comme identifiant que le compte de service peut lire.
Le mot de passe du broker n'est donc jamais dans un fichier que ce compte
pourrait ouvrir de lui-même.

Par-dessus, l'unité abandonne toutes les capacités et refuse tout ce dont elle
n'a pas besoin : `ProtectSystem=strict`, `PrivateDevices`,
`ProtectKernelTunables`, `RestrictAddressFamilies=AF_INET AF_INET6`,
`SystemCallFilter=@system-service`, et le reste. Un pont compromis serait un
processus non privilégié sachant ouvrir des sockets TCP, et à peu près rien
d'autre.

`LoadCredential` exige systemd 247+. En dessous, l'installeur le signale et se
rabat sur root plutôt que de poser une unité qui ne démarrerait pas.

## Entités Home Assistant

`homeassistant/mowgli_mqtt.yaml` définit 20 entités regroupées sous un appareil
`Mowgli`. Collez-le dans `configuration.yaml`, ou déposez-le dans
`config/packages/`. Redémarrez Home Assistant.

`homeassistant/mowgli_card.yaml` est une carte de tableau de bord construite
uniquement avec des cartes natives — pas de HACS. Collez-la dans l'éditeur YAML
brut de votre tableau de bord.

> **Identifiants d'entités.** Home Assistant construit l'`entity_id` à partir du
> nom de l'appareil et du nom de l'entité, et le fige à la création. La carte
> utilise les identifiants que produit le YAML fourni. Si vous renommez quoi que
> ce soit, mettez la carte à jour.

Deux entités méritent l'attention :

- **Lame en rotation** croise `mow_enabled` avec le régime réel du moteur. Une
  tondeuse qui croit tondre alors que la lame est à l'arrêt se voit ici, et
  nulle part ailleurs.
- **Code ESC lame** expose `mower_status`. `255` signifie que l'ESC ne répond
  pas du tout.

## Commandes

Le pont écoute aussi `mowgli/command` et traduit la charge utile en appel sur
l'API de services du robot — celle qu'utilise sa propre interface web :

```
POST /api/mowglinext/call/high_level_control   {"command": <n>}
```

| Charge utile | Effet | Code |
|---|---|---|
| `start` / `resume` | démarrer ou reprendre la tonte | `COMMAND_START=1` |
| `pause` / `stop` | arrêt sur place : mouvement stoppé, lame coupée, ne bouge plus | `COMMAND_STOP=8` |
| `dock` / `home` / `return_to_base` | retour à la base | `COMMAND_HOME=2` |
| `reset_emergency` | acquitter une urgence verrouillée — **en option** | `POST …/call/emergency {"emergency": 0}` |

L'acquittement passe par le service dédié `EmergencyStop`, pas par
`high_level_control`. `COMMAND_RESET_EMERGENCY=254` est bien déclaré dans
`HighLevelControl.srv`, mais le robot y répond `{}` et rien ne se produit —
sa propre interface appelle `mowerAction("emergency", {Emergency: 0})`, donc
le pont fait pareil.

Un mot simple ou `{"command": "dock"}` fonctionnent tous les deux. Tout ce qui
n'est pas reconnu est refusé et nommé, jamais deviné — ce topic pilote une
machine à lame.

Chaque commande reçoit une réponse sur `mowgli/command/result` :

```json
{"command":"dock","ok":true,"detail":"accepted by the robot","ts":1789767690}
```

Un refus est donc visible dans Home Assistant, pas seulement dans le journal.

### L'acquittement d'urgence est désactivé par défaut

`ALLOW_EMERGENCY_RESET=false`, sauf si vous avez répondu oui à l'installation.

Le raisonnement : votre broker accepte n'importe quel client disposant du
compte. Exposer le verrou d'urgence sur MQTT permet donc à n'importe quoi sur
votre réseau — une automatisation mal écrite, un script de test, un appareil
compromis — de lever un dispositif de sécurité sur une machine à lame. Ce
verrou s'est enclenché parce que quelque chose a mal tourné : le robot a été
soulevé ou penché. Juger que c'est de nouveau sûr se fait à côté de la machine.

Démarrer, pause et retour base n'ont pas ce poids : au pire, le robot rentre.

Le bouton est présent dans la carte dans tous les cas. Option désactivée, le
pont refuse et l'explique sur `mowgli/command/result`.


## Mettre à jour, reconfigurer, désinstaller

Il n'y a qu'un seul script. Relancez-le sur une machine qui a déjà le pont : il
vous dit ce qu'il a trouvé, puis demande.

```
mowglinext-ha-bridge est déjà installé
  programme  /usr/local/bin/mowglinext-ha-bridge
  config     /etc/mowglinext-ha-bridge.conf
  service    active

  1) Mettre à jour — nouveau programme, réglages conservés
  2) Reconfigurer  — reposer toutes les questions
  3) Désinstaller  — tout retirer
  4) Annuler
```

Les mêmes choix existent en options, pour les scripts et la commande en une
ligne :

```bash
sudo ./install.sh --update       # nouveau programme, réglages intacts
sudo ./install.sh --reinstall    # reposer toutes les questions
sudo ./install.sh --uninstall    # retirer, en demandant pour la config
sudo ./install.sh --purge        # retirer, fichier de config compris
sudo ./install.sh --help
```

### Tout supprimer en une ligne

```bash
curl -fsSL https://raw.githubusercontent.com/juditech3D/MowgliNext-ha-bridge/main/install.sh | sudo bash -s -- --purge
```

La désinstallation fait trois choses, dans cet ordre :

1. **arrête et désactive le service** — obligatoirement en premier, sinon
   l'étape suivante serait défaite dans la seconde ;
2. **efface les topics MQTT retenus.** Un message retenu survit au client qui
   l'a publié : sans cela, Home Assistant continuerait d'afficher votre dernier
   niveau de batterie indéfiniment, sans rien indiquant qu'il est figé ;
3. **supprime l'unité et le programme**, puis demande avant d'effacer le fichier
   de configuration, puisque c'est là que vit votre mot de passe.

Le robot n'est jamais touché, il n'y a donc rien à défaire de ce côté. Côté Home
Assistant, retirez le bloc `mqtt:` de `configuration.yaml` ainsi que la carte,
puis redémarrez.

## Au quotidien

```bash
sudo journalctl -u mowglinext-ha-bridge -f        # suivre le journal
sudo systemctl restart mowglinext-ha-bridge       # redémarrer
sudo nano /etc/mowglinext-ha-bridge.conf          # modifier les réglages
```

## Référence de configuration

| Clé | Défaut | Signification |
|---|---|---|
| `ROBOT_HOST` | `127.0.0.1` | Adresse du robot |
| `ROBOT_PORT` | `4006` | Port de l'interface web du robot |
| `MQTT_HOST` | — | Adresse du broker (obligatoire) |
| `MQTT_PORT` | `1883` | Port du broker |
| `MQTT_USERNAME` / `MQTT_PASSWORD` | — | Identifiants, vides pour anonyme |
| `MQTT_CLIENT_ID` | `mowglinext-ha-bridge` | Identité vue par le broker |
| `TOPIC_PREFIX` | `mowgli` | Préfixe de tous les topics |
| `MIN_PUBLISH_INTERVAL` | `2.0` | Secondes minimum entre deux envois d'un même topic |

Les variables d'environnement l'emportent sur le fichier, donc les surcharges
systemd fonctionnent.

`MIN_PUBLISH_INTERVAL` compte plus qu'il n'y paraît : le robot émet plusieurs
messages par seconde et par topic, et chacun deviendrait sinon une ligne dans la
base de l'enregistreur de Home Assistant.

## Limites

- **Lecture seule.** Pas de topic `mowgli/command` : les codes de commande sont
  documentés dans un `docs/MQTT_CONTROL.md` que l'interface du robot référence
  mais ne livre pas. Démarrer, mettre en pause et retourner à la base passent
  toujours par l'interface du robot.
- TLS vers le broker n'est pas implémenté. Sur un réseau domestique, 1883 en
  clair vers Mosquitto est le montage habituel.
- Testé sur MowgliNext v1.3.0. L'API WebSocket est celle que consomme
  l'interface du robot, elle a donc peu de chances de bouger, mais ce n'est pas
  un contrat de stabilité.

Si une version future de MowgliNext livre un pont fonctionnel, arrêtez ce
service — les noms de topics sont volontairement identiques.

## Licence

MIT. Voir [LICENSE](LICENSE).

# microservice-matchmaking
Microservice for searching opponents and building game sessions

Features
--------
- Written in Elixir with using OTP and RabbitMQ queues
- Configurable rating groups and their ranges
- Processing requests represented as a pipeline, so that you can scale each stage independently
- Tracking active players in queue with using Mnesia
- Sharing states between workers the server is trying to seed a player

Documentation
-------------
The information about how requests are handled in matchmaking microservice with using pipeline can be found [here](https://github.com/OpenMatchmaking/documentation/blob/master/docs/matchmaking.md#distributing-tasks-for-a-search).  
The general documentation about this microservice and available API is located [here](https://github.com/OpenMatchmaking/documentation/blob/master/docs/components/matchmaking-microservice.md).

License
-------
The microservice-matchmaking published under BSD license. For more details read [LICENSE](https://github.com/OpenMatchmaking/microservice-matchmaking/blob/master/LICENSE) file.

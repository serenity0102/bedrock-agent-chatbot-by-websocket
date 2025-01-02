import boto3
import json
import os
import uuid

def lambda_handler(event, context):
    if event['requestContext']['routeKey'] == 'sendmessage':
        return handle_message(event)
    return {'statusCode': 200}

def handle_message(event):
    connection_id = event['requestContext']['connectionId']
    domain = event['requestContext']['domainName']
    stage = event['requestContext']['stage']
    print(f"""connection_id: {connection_id}""")
    print(f"""domain: {domain}""")
    print(f"""stage: {stage}""")
    
    message = json.loads(event['body'])['message']
    print(f"""receive: {message}""")
    
    bedrock = boto3.client('bedrock-agent-runtime')
    api_client = boto3.client('apigatewaymanagementapi', 
                            endpoint_url=f'https://{domain}/{stage}')
    
    try:
        response = bedrock.invoke_agent(
            agentId=os.environ['AGENT_ID'],
            agentAliasId=os.environ['AGENT_ALIAS'],
            sessionId=f'session-apigateway',
            inputText=message,
            enableTrace=True
        )

        print(f"""response: {response}""")
        # response.get('completion') is botocore.eventstream.EventStream object, output all its content
        print(f"""response.get('completion'): {response.get('completion')}""")
        
        
        # Send intermediate steps
        for event in response.get('completion'):
            if 'chunk' in event:
                chunk = event['chunk']['bytes'].decode()
                step_data = {
                    'type': 'intermediate',
                    'content': chunk,
                    'trace': response.get('trace', {})
                }

                print(f"""step_data: {step_data}""")
                api_client.post_to_connection(
                    ConnectionId=connection_id,
                    Data=json.dumps(step_data)
                )
        
        # Send final response
        final_response = {
            'type': 'final',
            'content': response.get('completion'),
            'trace': response.get('trace', {})
        }
        print(f"""final_response: {final_response}""")
        api_client.post_to_connection(
            ConnectionId=connection_id,
            Data=json.dumps(final_response)
        )
        
        return {'statusCode': 200}
    except Exception as e:
        error_response = {
            'type': 'error',
            'content': str(e)
        }
        print(f"""exception e: {e}""")
        api_client.post_to_connection(
            ConnectionId=connection_id,
            Data=json.dumps(error_response)
        )
        return {'statusCode': 500}

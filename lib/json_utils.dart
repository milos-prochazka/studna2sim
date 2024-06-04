bool getBool(dynamic value, {bool defaultValue = false}) 
{
  if (value is bool) 
  {
    return value;
  } 
  else if (value is String) 
  {
    return switch (value.trim().toLowerCase()) 
    {
      'true' => true,
      'on' => true,
      '1' => true,
      _ => false,
    };
  } 
  else if (value is num) 
  {
    return value >= 0.5;
  } 
  else 
  {
    return defaultValue;
  }
}

double getDouble(dynamic value, {double defaultValue = double.nan}) 
{
  if (value is num) 
  {
    return value.toDouble();
  } 
  else if (value is String) 
  {
    return double.tryParse(value) ?? defaultValue;
  } 
  else if (value is bool) 
  {
    return value ? 1.0 : 0.0;
  } 
  else 
  {
    return defaultValue;
  }
}

int getInt(dynamic value, {int defaultValue = 0}) 
{
  if (value is num) 
  {
    return value.toInt();
  } 
  else if (value is String) 
  {
    return int.tryParse(value) ?? defaultValue;
  } 
  else if (value is bool) 
  {
    return value ? 1 : 0;
  } 
  else 
  {
    return defaultValue;
  }
}

String getString(dynamic value, {String defaultValue = ''}) 
{
  if (value is String) 
  {
    return value;
  } 
  else if (value is num) 
  {
    return value.toString();
  } 
  else if (value is bool) 
  {
    return value.toString();
  } 
  else 
  {
    return defaultValue;
  }
}

dynamic getItemFromPath(dynamic baseValue, List<dynamic> path) 
{
  var value = baseValue;

  for (var key in path) 
  {
    if (value is Map && key is String) 
    {
      value = value[key];
    } 
    else if (value is List && key is num) 
    {
      value = value[key.toInt()];
    } 
    else 
    {
      return null;
    }
  }

  return value;
}

T stringToEnum<T extends Enum>(List<T> values, String value) 
{
  for (var enumValue in values) 
  {
    if (enumValue.name == value) 
    {
      return enumValue;
    }
  }

  return values.first;
}